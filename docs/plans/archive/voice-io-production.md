# 音声入出力の本実装（TurnBasedVoiceSession を製品品質へ）

## 目的・背景

スパイクで作った `TurnBasedVoiceSession`（案 A2: クラウド STT + Claude + クラウド TTS のターン制）は
「一度つないで動かす」ことしか考えていない。実際に毎日使うには以下が欠けている。

- **STT 接続断で会話が死ぬ**: `connectionFailed` を受けると即 `stop()`。Wi-Fi ⇔ LTE の切替や
  サーバ側のセッション打ち切りで会話全体が終了し、履歴も消える
- **割り込みに無防備**: 電話・アラーム・Siri・バックグラウンド遷移・イヤホン抜き差しをどこも監視していない。
  AVAudioEngine が黙って止まり、見た目は動いているのに聞き取れない状態になる
- **エラーの扱いが未分類**: `.failure` が「Claude ターン 1 回の失敗」と「API キー未設定」の両方に使われている。
  致命的エラーでもセッションが半端に生き残るパス（start 途中の失敗）があり、復帰導線がない

## 対応方針

セッションの寿命の考え方を「使い捨て」から「**start〜stop の間は自力で生き延びる**」に変える。
`OpenAITranscriptionStream` 等の下位コンポーネントは使い捨てのまま、作り直し（再接続）を
`TurnBasedVoiceSession` がオーケストレーションする。`VoiceSession` プロトコルの形（start/stop/events）は変えない。

### Phase 1: STT 自動再接続

- `ReconnectPolicy`（新規・純粋ロジック）: 試行回数と backoff（0.5s → 1s → 2s、最大 3 回）を管理。
  接続成功（ready）でカウンタをリセット。テスト対象
- `TurnBasedVoiceSession`: `connectionFailed` を致命扱いから再接続トリガーへ変更
  - 古い transcriber を破棄 → 新しい `OpenAITranscriptionStream` を生成 → `ready` で listening へ復帰
  - マイクは動かしたまま（`micStreamTask` は `self.transcriber` を参照しているので差し替えだけで良い)
  - 切断時に `isUserSpeaking` / `pendingSegments` をリセット。確定済み `pendingTurnText` は保持し、
    再接続後に commit する（発話が丸ごと消えるのを防ぐ）
  - backoff 尽きたら致命エラー（Phase 3 の fail 導線）
- `VoiceSessionState` に `.reconnecting` を追加（UI 表示「再接続中…」）
- `OpenAITranscriptionStream` に ping keepalive（15s 間隔、失敗で切断扱い）を追加。
  ネットワーク切替時に receive がエラーも返さず沈黙するケースの検知用

### Phase 2: バックグラウンド遷移・オーディオ割り込み対応

`TurnBasedVoiceSession` が NotificationCenter を直接監視する（UI 層にオーディオ知識を漏らさない）。

- `AVAudioSession.interruptionNotification`: began → suspend / ended（shouldResume）→ resume
- `UIApplication.didEnterBackgroundNotification` → suspend / `willEnterForegroundNotification` → resume
- `AVAudioSession.routeChangeNotification`（oldDeviceUnavailable 等）: エンジン再起動（STT 接続は維持）
- `AVAudioSession.mediaServicesWereResetNotification`: AVAudioEngine の作り直しが必要になるが
  発生は稀なので、明示的なエラー終了（開始し直しで復帰）とする
- suspend: マイク停止・TTS 即時停止・Claude ターンキャンセル・STT 切断。会話履歴は保持。state = `.suspended`
- resume: オーディオセッション再アクティベート → エンジン再起動 → STT 再接続（Phase 1 の機構を再利用）
- `VoiceSessionState` に `.suspended` を追加（UI 表示「一時停止中」）
- `RealtimeAudioPlayer.prepare()` を再入可能にする（attach 済みノードの二重 attach を避け、resume で再利用）
- 会話中の画面自動ロック防止: セッション実行中は `UIApplication.isIdleTimerDisabled = true`
  （ViewModel 側。放置でロック → バックグラウンド遷移で会話が切れるのを防ぐ）

### Phase 3: エラー分類と復帰導線

- **致命的**（セッション終了）: API キー未設定 / マイク権限拒否 / オーディオセッション初期化失敗 /
  再接続 backoff 尽き / マイク再起動失敗
  - `.failure` はこのケース専用にする。必ず `stop()` を伴わせ、events ストリームを finish させて
    ViewModel を確実にデタッチする（現状は start 途中の失敗でセッションが半端に生き残る）
  - UI はエラーメッセージ + 「会話を開始」ボタンで再開できる（既存 UI の整理で足りる）
- **回復可能**（ターン単位、セッション継続）: Claude API エラー / TTS 1 文の取得失敗 / STT 1 セグメント認識失敗
  - Claude ターン失敗は 1 秒後に 1 回だけ自動リトライ。それでも失敗したら `.info` 通知
    「応答の取得に失敗しました。もう一度話しかけてください」で listening に戻す
  - TTS / STT のセグメント失敗は現行どおり通知 + スキップ継続
- `stop()` 時に `AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)` を追加
  （他アプリの音楽再生等を戻す）

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Voice/TurnBasedVoiceSession.swift` | 中心。再接続・suspend/resume・エラー分類 |
| `Voice/ReconnectPolicy.swift` | 新規（純粋ロジック） |
| `Voice/VoiceSession.swift` | `VoiceSessionState` に `.reconnecting` / `.suspended` 追加 |
| `Voice/CloudPipeline/OpenAITranscriptionStream.swift` | ping keepalive 追加 |
| `Voice/Realtime/RealtimeAudioPlayer.swift` | `prepare()` の再入対応 |
| `Voice/MicrophoneCapture.swift` | 再起動まわりの微修正（必要なら） |
| `Conversation/ConversationView.swift` | 新 state のラベル・アイコン追加 |
| `Conversation/ConversationViewModel.swift` | idle timer 制御 |
| `EslSpeakingCoachTests/ReconnectPolicyTests.swift` | 新規 |

案 B（Realtime）/ 案 C（Gemini Live）のセッションは触らない（別タスクで削除予定）。
`VoiceSessionState` の case 追加は各ビューの switch を網羅更新するだけで済む。

## テスト方針

- **ユニットテスト**: `ReconnectPolicy`（backoff 系列・上限・成功リセット）
- **ビルド**: `xcodegen generate` + `xcodebuild`（シミュレータ）が通ること
- **シミュレータ E2E**: テキスト入力での会話フロー（Claude / TTS）が退行していないこと
- **実機（手動チェックリスト、このタスクでは未実施なら明記する）**:
  1. 会話中に電話着信 → 通話終了後に会話へ復帰できる
  2. 会話中にホームへ戻る → アプリに戻ると再接続して続きが話せる
  3. 会話中に機内モード ON→OFF → 自動再接続する（backoff 中の表示を確認）
  4. AirPods の接続・切断で音声入出力が生き残る
