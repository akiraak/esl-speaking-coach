# 会話終了ボタンでアプリが落ちる — 調査プラン

## 目的・背景

トーク画面下端の「このトピックを終了」→ 確認アラートの「終了する」を押したところ、
アプリがクラッシュした（実機・1 回観測）。

会話セッションの終了はフィードバック生成・記憶ノート更新・次トピック提案の起点であり、
ここで落ちると **その回の会話のフィードバックが得られない**（履歴自体は発話ごとに保存済みなので
失われないが、`endedAt` が入らないまま残り、次回起動時に `closeUnfinishedSessions()` で閉じられる）。

現時点で **クラッシュログを未回収**のため、まず事実を確定させてから直す。
本プランは「情報回収 → 切り分け → 仮説検証 → 対策」の調査プランであり、
Phase 3 の対策内容は原因が確定してから確定させる。

## 現状の終了パスの整理（コードから）

押下から落ちうる範囲までの流れ:

1. `ChatRoomView.swift:45-50` 確認アラート →`store.endSession()`
2. `ChatRoomStore.endSession()`（`ChatRoomStore.swift:332`）
   → `isEndingSession = true` → `session.stop()`
3. `TurnBasedVoiceSession.stop()`（`TurnBasedVoiceSession.swift:234`）
   - オブザーバ解除 → `claudeTask.cancel()` → `tearDownSTT()` → `levelTask.cancel()`
   - `speaker.shutdown()`（TTS フェッチ中断 + `AVAudioEngine.stop()`）
   - `microphone.router.detachRaw()` → `microphone.stop()`（タップ解除 + 入力エンジン停止）
   - `AVAudioSession.setActive(false, .notifyOthersOnDeactivation)`
   - `state = .idle` → `eventContinuation.finish()`
4. events の for-await が抜けて `ChatRoomStore.handleSessionFinished()`（`ChatRoomStore.swift:382`）
   - `session = nil`（= `TurnBasedVoiceSession` の解放） / `isIdleTimerDisabled = false`
   - `historyStore.endActiveSession()`（`ChatHistoryStore.swift:128`。**発話 0 件ならセッションを delete**）
   - `postFeedbackCard()` → `updateCharacterMemory()` → `scheduleTranslationFlush()` → `postTopicCard()`
   - タイムラインに 2 枚（フィードバックカード + トピックカード）を追記 → `timelineRevision` 変化で自動スクロール

重要な性質: **goodbye による自動終了（`.sessionEndDetected`）は 3. 以降がまったく同じ**
（`ChatRoomStore.swift:771-774`）。自動終了で落ちた報告はないので、
違いは「**押した瞬間の状態**」にある可能性が高い。自動終了は必ず読み上げ完了直後
（`handleTurnFinished` の中）で、オーディオが静止し Claude ストリームも終わっている。
一方、手動終了は `speaking`（TTS 再生中）/ `thinking`（Claude SSE 受信中）/ `reconnecting` /
`suspended` のいずれでも起こりうる。→ **切り分けの第一軸は「押したときの状態」**。

## 仮説（優先度順）

### H1. 読み上げ中に押した場合のオーディオ停止順序（AVFoundation の例外 / アサート）

- `StreamingAudioPlayer.shutdown()` は `player.stop()` / `engine.stop()` を呼ぶが、
  `enqueue(pcm16Data:marker:)`（`StreamingAudioPlayer.swift:56`）には
  **`engine.isRunning` のガードが無い**（ジングル用の `playCue()` にはある = `swift:79`）。
  停止済みエンジンに対する `scheduleBuffer` / `play()` は
  `required condition is false: _engine->IsRunning()` の NSException で abort する。
- 現状は `CloudSentenceSpeaker` の世代カウンタ（`turnID`）で
  `player.enqueue` の直前にチェックが入っており（`CloudSentenceSpeaker.swift:121`）、
  MainActor 上なので **理屈上は塞がっている**。ただし
  - TTS の SSE デコード側から別経路で流れ込む可能性
  - `restartAudioIO` / `resume` の `speaker.prepare()` と競合する経路
  が残るため、実測で否定するまでは第一候補として扱う。
- **確認方法**: クラッシュログの例外種別が `EXC_BREAKPOINT` + `com.apple.coreaudio.avfaudio`、
  最終フレームが `AVAudioPlayerNode` / `AVAudioEngine` なら確定。
- **切り分け**: 「読み上げ中に押す」を 5 回、「入力待ち（無音）で押す」を 5 回。

### H2. 入力側（マイク）の停止漏れ

- `stop()` は `stopMicrophoneStreaming()` を経由せず個別に
  `detachRaw()` + `microphone.stop()` を呼んでいる（`TurnBasedVoiceSession.swift:247-248`）。
  その結果 **`micStreamTask` と `micWatchdogTask` が cancel されない**。
  - `micWatchdogTask` は 2 秒 sleep 後に `guard !self.isStopped` で抜けるので実害は無いはずだが、
    `guard let self` で **セッションを 2 秒間強参照し続ける**（= `AVAudioEngine` の解放が遅れる）。
  - `handleSessionFinished` で `session = nil` した後、watchdog 経由の最後の参照が切れた時点で
    `MicrophoneCapture` / `StreamingAudioPlayer` が deinit される。タップやレンダースレッドが
    完全に止まる前の解放は AVAudioEngine 系のクラッシュ定番パターン。
- **確認方法**: クラッシュログのスレッドが audio render（`caulk` / `AURemoteIO`）系か。
  再現時は「終了ボタン押下から落ちるまでの遅延（即座か 1〜2 秒後か）」も記録する。
- 押下から **数秒遅れて**落ちたなら H2 の疑いが濃い。

### H3. SwiftData（発話 0 件セッションの削除と、その後の参照）

- `endActiveSession()` は発話 0 件なら `context.delete(activeSession)`（`ChatHistoryStore.swift:130-132`）。
  ログ（`ChatSessionLogRecord`）は cascade で消える設計（`ChatHistoryModels.swift:44`）。
- 削除後も `activeSessionID` は `handleSessionFinished` 内で `postFeedbackCard` に渡され、
  `usageStore.record(usage, sessionID:)`（`ChatRoomStore.swift:650, 770`）や
  `saveFeedback` から参照されうる。UUID 値渡しなので即クラッシュはしないはずだが、
  **削除済みモデルへのアクセスは SwiftData で abort する**ため要確認。
- 特に疑わしいのは「トピックを開始してすぐ（1 度も話さずに）終了した」ケース。
  このとき STT 接続の `.info` ログだけがぶら下がった状態で親が delete される。
- **確認方法**: 例外が `SwiftData` / `CoreData` フレームで、
  メッセージが `NSValidationRelationshipDeniedDeleteError` や
  `This model instance was destroyed` 系か。
- **切り分け**: 「開始直後・発話 0 件で終了」を単独で試す（フィードバックもスキップされる経路）。

### H4. SwiftUI（終了直後のタイムライン更新と自動スクロール）

- 終了処理は同一ターンで **カード 2 枚を追記**しつつ、
  `isSessionActive` が false になって下端バーの終了ボタンが消え（`ChatRoomView.swift:189`）、
  `timelineRevision` の変化で `ScrollViewReader.scrollTo` がアニメーション付きで走る。
  さらにアラートの dismiss アニメーションが同時進行する。
- ID 重複（`ForEach` の同一 UUID）は現状のコード上は起きないはずだが、
  復元済みフィードバックカードとの取り違え等がないか確認する。
- **確認方法**: クラッシュログが `SwiftUI` / `UIKit` フレームなら本命。
  シミュレータ（マイク無効 = オーディオ入力パス無し）で再現するかが決定的な切り分けになる。

### H5. その他（記録のみ）

- `stop()` の二重呼び出し（アラートの多重タップ、goodbye と手動終了の競合）→ `isStopped` で塞がっている
- `AppModelContainer` の `try!`（`AppModelContainer.swift:12`）→ 起動時のみで終了時は無関係
- Keychain 読み出し失敗 → `try?` で握っている

## Phase 構成

### Phase 0: クラッシュの事実回収 ✅ 実装済み

**次に落ちたときに自動で手がかりが残るよう、診断ログを入れた**（2026-07-27）。

- `EslSpeakingCoach/Support/DiagnosticsLog.swift`（新規）
  - Application Support 配下の `Diagnostics/app.log` へ **O_APPEND の write(2) で追記**する。
    バッファに溜まらないので abort しても書いた分は残る
  - 起動ごとにバナー行（アプリ版数 / iOS / 機種）を挟む。上限 256KB を超えたら末尾 128KB を残して切り詰め
  - `NSSetUncaughtExceptionHandler` で **未捕捉の Objective-C 例外**（AVFoundation のアサートはこれ）
    の name / reason / スタックを記録する
  - `SIGABRT / SIGILL / SIGSEGV / SIGFPE / SIGBUS / SIGTRAP` のハンドラで
    `backtrace_symbols_fd` を使いバックトレースを直接 fd へ書く（malloc しない）。
    記録後は `SIG_DFL` に戻して `raise` するので、**OS のクラッシュレポート（.ips）も従来どおり残る**
- 足跡（breadcrumb）を仕込んだ場所
  - 終了ボタン押下: 押した瞬間の `state` / 入力モード / ⏸ / 学習者の発話数（`ChatRoomStore.endSession`）
  - `TurnBasedVoiceSession.stop()` の各段（STT・Claude → 読み上げ → マイク → オーディオセッション → 完了）
  - `CloudSentenceSpeaker.shutdown` / `StreamingAudioPlayer.shutdown`（エンジンの running / playing / 未再生バッファ数）
  - **H1 の直前検知**: 停止済みエンジンに `enqueue` が来たら `!! player: エンジン停止中に…` を残す
    （**挙動は変えていない**ので、H1 が原因ならこの行の直後に落ちる = 一発で確定する）
  - `MicrophoneCapture.stop`、セッション開始、シーンの前面 / 背面遷移
- 読み方: **管理画面（📊）→「診断」タブ**。全文コピー / 再読み込み / クリアができる。
  前回起動ぶんも残っているので、落ちたら再起動してここを見る
- 動作確認済み（シミュレータ）: 終了処理の全段が時系列で残ること、
  `-crash-test exception` / `-crash-test fatal`（DEBUG 限定の起動引数）で
  例外・シグナル双方が原因箇所付きのバックトレースとして残ること

次に落ちたときにやること:

- 管理画面 →「診断」→ 全文をコピーして共有する（`!!!` の行とその直前の足跡が決定的）
- 併せて実機のクラッシュログも回収する。いずれか:
  - Xcode > Window > Devices and Simulators > View Device Logs
  - 端末の 設定 > プライバシーとセキュリティ > 解析と改善 > 解析データ >
    `EslSpeakingCoach-YYYY-MM-DD-*.ips` を共有
- 以下を記録する（ログが取れなくても切り分けに効く）
  - 押したときの状態（AI が読み上げ中 / 考え中 / 入力待ち / エラー再開バーが出ていた）
  - 入力モード（音声 / テキスト）、⏸ 中だったか
  - そのセッションで自分が何回話したか（0 回か 2 回以上か）
  - 押してから落ちるまでの体感（即座 / 1〜2 秒後）
  - 再起動後にその会話が履歴に残っていたか、フィードバックは出たか
- **完了条件**: 診断ログの `!!!` 行 + 直前の足跡、または `.ips` のスタックトレースが揃う

### Phase 1: 再現の切り分け

- Xcode からデバッグ実行して attach した状態で再現を試す（例外の発生箇所がそのまま取れる）
- 切り分けマトリクス（各 3〜5 回）
  | # | 状態 | 入力モード | 発話数 | 期待する切り分け |
  | --- | --- | --- | --- | --- |
  | 1 | 読み上げ中 | 音声 | 2 以上 | H1 |
  | 2 | 入力待ち（無音） | 音声 | 2 以上 | H1 を否定できる |
  | 3 | 開始直後・未発話 | 音声 | 0 | H3 |
  | 4 | 読み上げ中 | テキスト | 2 以上 | 入力パス（H2）の切り分け |
  | 5 | シミュレータ・読み上げ中 | テキスト | 2 以上 | オーディオ入力なしで再現するか（H4） |
- **完了条件**: 100% 再現する手順、または「特定条件でのみ稀に落ちる」ことの確定

### Phase 2: 仮説の検証と原因確定

- Phase 0/1 の結果で H1〜H4 を絞り、該当箇所へ一時的な診断ログ（`historyStore.appendLog(kind: .notice, ...)`）
  を仕込んで確定させる。会話ログは管理画面から読めるので、実機で落ちても再起動後に確認できる
- **完了条件**: 原因が 1 つに特定され、落ちる条件がコードで説明できる

### Phase 3: 対策

原因確定後に確定させる。原因に関わらず入れておく価値がある防御は以下（要検討）:

- `StreamingAudioPlayer.enqueue` に `engine.isRunning` ガードを足す（`playCue` と同じ形に揃える）
- `TurnBasedVoiceSession.stop()` を `stopMicrophoneStreaming()` 経由にして
  `micStreamTask` / `micWatchdogTask` も確実に cancel する
- `micWatchdogTask` の `guard let self` を弱参照のまま扱い、停止後にセッションを延命させない
- `handleSessionFinished` で削除済みセッションを参照しない（発話 0 件時は `activeSessionID` を先に捨てる）

### Phase 4: 検証と後片付け

- ユニットテストを追加する（`EslSpeakingCoachTests/`）
  - `stop()` 後に読み上げ・マイク経路へイベントが来ても落ちない
  - `stop()` の二重呼び出し・`speaking` 中の `stop()` で状態と events が期待どおり終わる
  - 発話 0 件セッションの `endActiveSession()` 後に `saveFeedback` / `updateTranslation` を呼んでも安全
- 実機で Phase 1 のマトリクスを再走させて落ちないことを確認する
- 仕様書（`docs/specs/conversation-design.md` のセッション終了）に必要なら反映し、
  本プランを `docs/plans/archive/` へ移動、TODO を DONE へ

## 影響範囲

- `EslSpeakingCoach/Support/DiagnosticsLog.swift`（Phase 0 で新規追加）
- `EslSpeakingCoach/Admin/DiagnosticsLogView.swift`, `AdminView.swift`（診断タブ）
- `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift`（stop の停止順序・タスク解放）
- `EslSpeakingCoach/Voice/CloudPipeline/StreamingAudioPlayer.swift`, `CloudSentenceSpeaker.swift`
- `EslSpeakingCoach/Voice/MicrophoneCapture.swift`
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift`（`handleSessionFinished` 前後）
- `EslSpeakingCoach/Persistence/ChatHistoryStore.swift`（発話 0 件セッションの削除）

## テスト方針

- ユニットテストは `VoiceSession` 境界の内側（Player / Speaker / Store）で純粋に検証できる範囲に閉じる
- オーディオの実挙動（AVAudioEngine の停止順序）は**実機でしか確認できない**ため、
  Phase 1 のマトリクスを実機で再走させることを最終確認とする
- シミュレータはマイク無効・`playback` カテゴリのため、H1/H4 の切り分けにのみ使う
