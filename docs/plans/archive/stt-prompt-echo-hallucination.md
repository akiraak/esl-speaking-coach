# STT prompt エコー幻覚の調査と対策

## 目的・背景

Hum など考え中の小さい声を出したとき、ユーザー発話として以下の長い文章が入力されることがある。

> The speaker is a Japanese adult practicing English conversation. The audio is always English

### 調査結果（2026-07-26）

この文章は **STT に渡している認識バイアス用 prompt そのもの**である。
`OpenAITranscriptionConfiguration.prompt`（`EslSpeakingCoach/Voice/CloudPipeline/OpenAITranscriptionProtocol.swift`）:

```
The speaker is a Japanese adult practicing English conversation. \
The audio is always English.
```

発生メカニズム:

1. Hum・咳・息などの小さな声でもサーバ VAD（`silence_duration_ms: 800`）が発話セグメントとして区切ることがある
2. gpt-4o-transcribe（Whisper 系）は、**実質無音・非発話のセグメント**を認識するとき、条件付けに使った prompt テキストをそのまま「書き起こし」として出力する既知の幻覚モード（prompt leakage）を持つ
3. `TurnBasedVoiceSession.handleSTTEvent` の `.finalTranscript` は空文字しか弾かないため（`TurnBasedVoiceSession.swift` の trim → `!trimmed.isEmpty` チェックのみ）、prompt エコーはユーザー発話としてそのまま commit され、Claude が謎の英文に応答してしまう

つまり「language=en の誤判定対策として入れた prompt」（コメント参照）の副作用。prompt を消せば直るが、短い発話の言語誤判定が再発するためトレードオフになる。

なお同じ非発話セグメントは barge-in（`speech_started` で応答中断）も誤発火させるが、本件のスコープは transcript への混入とする。

## 対応方針

### 案 A: prompt エコーフィルタ（採用・即効）

確定 transcript が設定中の prompt の「エコー」なら破棄する。

- 純関数 `isPromptEcho(transcript:prompt:)` を追加（正規化: 小文字化・句読点/空白除去 → transcript が prompt の部分文字列、または prompt の繰り返しで構成される場合に true。誤爆防止に最小長を設ける）
- `TurnBasedVoiceSession` の `.finalTranscript` 処理で、trim 後にこのフィルタを通す。破棄時は空セグメントと同じ扱い（`commitPendingTurnIfReady` で listening へ戻る）
- partial（UI 表示）にも同じ判定を適用するかは任意（final で弾けば会話には入らない。UI の一瞬の表示は許容可）

### 案 B: サーバ VAD の閾値調整（実機で併用検討）

`turn_detection` に `threshold`（既定 0.5）を明示して上げる（0.6〜0.7 目安）。Hum で VAD 自体が発火しにくくなり、誤 barge-in も減る。小声の話し始めを取りこぼすリスクがあるため実機で調整する。

### 見送り

- prompt の削除・短縮: 言語誤判定対策と排他になるため維持する
- logprobs による信頼度フィルタ（`include: ["item.input_audio_transcription.logprobs"]`）: 汎用的だが閾値設計が必要。将来 "Thank you for watching" 系の一般幻覚が問題になったら再検討

## 影響範囲

- `EslSpeakingCoach/Voice/CloudPipeline/OpenAITranscriptionProtocol.swift`（またはフィルタ用の新規ファイル）: 純関数の追加
- `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift`: `.finalTranscript` 処理にフィルタ適用
- 案 B を併用する場合: `OpenAITranscriptionClientEvent.sessionUpdate` の `turn_detection` に `threshold` 追加

## テスト方針

- ユニットテスト（`CloudPipelineProtocolTests` 相当）: 完全一致エコー / 末尾切れエコー / 2 回繰り返しエコー / prompt と単語が偶然重なる正当な発話（破棄されないこと）/ 空文字
- `xcodebuild` でビルド確認
- 実機: 考え中に Hum・咳払いをして prompt 文が入力されないこと、通常の短い発話（"Hello" 等）が英語のまま認識されること
