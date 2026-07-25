# 会話画面の UI（トークルーム化 + 2 キャラ台本対応）

## 目的・背景

[screen-layout.md](../specs/screen-layout.md) と [conversation-design.md](../specs/conversation-design.md) で決定した
「常設グループトークルーム + Chobi / Naruko の 2 キャラ台本方式」を実装する。
現状はプロトタイプ画面（1 キャラ・開始/停止ボタン・検証用メトリクス表示）のため、
UI の全面刷新と、その前提になる会話コアの 2 キャラ対応（仕様書の「影響範囲」）を併せて行う。

スコープ外（別タスク）: SwiftData 永続化（アプリ再起動でタイムラインは消える）、
セッション後のフィードバック生成（フィードバックカードは未実装のまま）、モデル・パラメータの最終調整。

## 対応方針

### Phase 1: 台本方式の会話コア（UI 非依存の下回り）

- `ChatCharacter`（新規）: `chobi` / `naruko`。表示名・アバター色・TTS voice（Leda / Aoede）・スタイル前置文をアプリ内定義の固定値で持つ
- `CoachSystemPrompt` を conversation-design.md 付録 A の 2 キャラ台本プロンプトへ全面置き換え
- `ScriptStreamChunker`（新規）: SSE デルタを逐次受け、行頭タグ（`Chobi: ` / `Naruko: `）で speaker 確定 →
  文境界で `(発話 index, speaker, 文)` を切り出す。改行 = 発話境界 = speaker リセット。
  タグがデルタ境界で割れても行バッファで吸収。タグ無し行は直前 speaker（ターン先頭は Chobi）へフォールバック。
  単独行 `[end]` を検知フラグにし、表示・読み上げ対象から除去する
- 既存 `SentenceChunker` は内部部品として温存

### Phase 2: TTS の speaker 対応

- `SpeechStyle`（voice 名 + スタイル前置文）を `SentenceTTSClient.streamPCM` の引数に追加。
  Gemini は voice / 前置文とも切替、OpenAI（聞き比べ用）は前置文のみ反映
- `CloudSentenceSpeaker.enqueue` を `(utteranceID, 文, SpeechStyle)` に変更し、
  発話（utterance）の最初のチャンクにマーカーを付けて `StreamingAudioPlayer` へ流す
- `StreamingAudioPlayer` にバッファ列と並行するマーカーキューを持たせ、
  発話の音声が実際に再生開始された時点で `onUtteranceAudioStarted(id)` を発火する
  （吹き出しを「読み上げ開始時に表示」するため）

### Phase 3: セッションエンジン改修（TurnBasedVoiceSession）

- イベント刷新: `assistantTextDelta` / `assistantTurnCompleted(fullText)` を廃止し、
  発話単位の `assistantUtteranceBegan(id, speaker, text)` / `assistantUtteranceUpdated(id, text)` +
  `assistantTurnCompleted` + `sessionEndDetected`（goodbye `[end]`）へ
- **履歴確定のタイミングを SSE 完了時から再生完了 / barge-in 時へ移動**:
  - 正常完了（全発話読み切り）→ 全発話をタグ付き台本 1 メッセージとして履歴確定
  - barge-in / suspend → 読み上げ開始済みの発話までを確定し、未読み上げ分は履歴・UI とも破棄（仕様どおり）
- テキスト / 音声の入力モード: `submitTypedUserTurn` を DEBUG 限定から昇格。
  `setVoiceInputEnabled(Bool)` で STT + マイクだけを起動 / 停止する（TTS 再生は常に有効）。
  テキストモードでは STT 非接続のまま `listening` になる。speaking 中のテキスト送信は barge-in 扱い
- トピック開始: `Configuration.initialTopic` を追加。ready（listening）になった時点で
  user メッセージ `[New topic: X]` を履歴に積み、AI 側から開始ターンを生成する
- `[end]` 検知 → closing 読み上げ完了後に `sessionEndDetected` を通知（表示・読み上げはしない）

### Phase 4: トピック生成クライアント

- `TopicSuggestionClient`（新規）: `claude-sonnet-5` / 非ストリーミング / `effort: low` /
  `output_config.format` の structured outputs（付録 B スキーマ）で候補 3 件（title + hook）を取得。
  `stop_reason == "refusal"` を先に確認してから content を読む
- user メッセージに直近トピックタイトルを渡して重複回避（永続化前は起動内メモリ）。
  「Free talk」はアプリ側の固定候補

### Phase 5: トークルーム UI（案 D「ポップ・スタディ」）

- `ChatRoomStore`（新規・@Observable）: ルームのタイムライン（セッション区切り / AI・ユーザーメッセージ /
  トピックカード / システムメッセージ）、アクティブセッション管理、入力モード（UserDefaults で永続）、
  トピックカードの投稿・再生成・選択、セッション終了 → 次カード投稿のフロー
- `ChatRoomView`（新規）: 起動直後に表示される主画面
  - ヘッダ: "ESL Group (3)" + ⋯ メニュー（トピックを終える）+ ⚙（設定シート）
  - タイムライン: AI = 左寄せ・アバター + 名前、ユーザー = 右寄せコーラル、ライブ文字起こし = 半透明・斜体、
    「入力中…」ドットインジケータ、読み上げ中キャラに 🔊、自動スクロール（手動で遡り中は停止）
  - トピックカード: 候補 3 件（タイトル + フック文）+ Free talk、🔄 再生成、＋自分で（アラート入力）、
    選択済みカードはグレーアウト
  - 入力バー: テキストモード（🎤 / フィールド / ↑）⇔ 音声モード（⌨ / 波形 / ⏸）。波形はマイクレベル連動
  - カラー・形状は screen-layout.md の案 D パレットどおり。ダークモードは未決のため当面ライト固定
    （`preferredColorScheme(.light)`。ダーク配色は別タスク）
- 旧 `ConversationView` / `ConversationViewModel` は削除。`ContentView` は ChatRoomView を直接ホスト
- 検証用表示（RMS・レイテンシ・TTS 切替 UI）は製品画面から撤去（レイテンシは DEBUG のみ小さく表示）

### Phase 6: ビルド・テスト・シミュレータ確認

- 単体テスト: `ScriptStreamChunker`（タグ分割・[end]・フォールバック）、タグ付き台本の再直列化、
  `TopicSuggestionClient` のリクエスト生成 / レスポンスパース、TTS リクエストの voice / スタイル切替
- 既存テスト（CloudPipelineProtocolTests 等)のプロトコル変更追随
- `xcodegen generate` → `xcodebuild build` / `test` → シミュレータ（iPhone 17）で表示・テキスト会話・
  トピックカードフローを目視確認。音声モード（マイク・波形・barge-in）は実機確認が必要な旨を明示する

## 影響範囲

- 新規: `ChatCharacter` / `ScriptStreamChunker` / `TopicSuggestionClient` / `ChatRoomStore` / `ChatRoomView`（+ 部品ビュー・テーマ）
- 変更: `CoachSystemPrompt` / `VoiceSession`（イベント・プロトコル）/ `TurnBasedVoiceSession` /
  `SentenceTTSClient` / `GeminiTTSClient` / `OpenAITTSClient` / `CloudSentenceSpeaker` / `StreamingAudioPlayer` /
  `ContentView` / `DebugLaunchArguments`
- 削除: `ConversationView` / `ConversationViewModel`

## テスト方針

- ロジック（チャンカー・直列化・リクエスト生成）は XCTest で網羅
- UI・会話フローはシミュレータで目視確認（テキストモード）。音声モードは実機確認項目として残す
- 受け入れ条件は screen-layout.md / conversation-design.md の該当チェックリストに従う
