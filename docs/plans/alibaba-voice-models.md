# Alibaba 音声モデル（Qwen3-TTS / Qwen3-ASR）の実機検証プラン

2026-08-01 作成。[cheap-chinese-ai-models.md](archive/cheap-chinese-ai-models.md) の Phase 1・Phase 4 から派生した検証タスク。

## 目的・背景

- LLM 置き換え調査（cheap-chinese-ai-models）は Phase 5 で**全経路見送り**が確定した。残った節約チャンスは音声レイヤ
- 現行コスト（1 セッション約 $0.52）のうち TTS $0.15 + STT $0.09 = **$0.24 が音声**で最大の費目。Alibaba の Qwen3 音声モデルは現行比 約 1/3 の単価:

| 経路 | 現行 | Alibaba 候補 | 換算 | 差 |
| --- | --- | --- | --- | --- |
| TTS | Gemini 3.1 Flash TTS ≈ $0.03/分 | qwen3-tts-flash-realtime（$0.13/1 万字） | ≈ $0.0098/分 | 約 1/3 |
| STT | gpt-live-transcribe $0.017/分 | qwen3-asr-flash-realtime（$0.000090/秒） | $0.0054/分 | 約 1/3 |

- 置き換えれば**月 約 $5 の節約**（毎日 1 セッション想定）。無料枠（TTS 11 万字・ASR 10 時間 / 90 日、シンガポールリージョン限定）で検証コストはほぼゼロ
- API キーは cheap-chinese-ai-models の Phase 2 で配置済み（`.secrets/dashscope-api-key`、SG リージョン）
- qwen3-asr-flash は HF Open ASR Leaderboard 1 位（WER 4.25%）の評があり英語精度は有望。TTS の英語ネイティブらしさは実聴確認が必要

## 机上調査サマリ（2026-08-01 実施）

両モデルとも WebSocket リアルタイム API があり、現行パイプラインと同型に載る見込み。

**TTS（qwen3-tts-flash-realtime）**:

- エンドポイント: `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime`（国際版）。認証は `Authorization: bearer {key}`
- イベント: `session.update`（voice / `response_format: PCM_24000HZ_MONO_16BIT` / mode）→ `input_text_buffer.append` (+`commit`) → `response.audio.delta`（base64）→ `response.done` → `session.finish`
- **出力 24kHz PCM16 mono = 現行 Gemini TTS と同一** → 再生パイプラインはそのまま使える見込み
- mode は `commit`（クライアントが文単位で明示 commit）と `server_commit`（サーバが自動分割）。現行の文単位 TTS には `commit` が同型
- voice は英語向けを要選定（例: Cherry。一覧は実行時に確認)
- 出典: https://www.alibabacloud.com/help/en/model-studio/qwen-tts-realtime / https://www.alibabacloud.com/help/en/model-studio/realtime-tts-user-guide

**ASR（qwen3-asr-flash-realtime）**:

- エンドポイント: ドキュメント上は**ワークスペース専用ドメインのみ** `wss://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/realtime?model=...`（`dashscope-intl` ドメインで使えるかは Phase 1 で実測確認）
- イベント名は OpenAI Realtime とほぼ同型: `session.update` → `input_audio_buffer.append` / `input_audio_buffer.commit` → `conversation.item.input_audio_transcription.text`（partial）/ `.completed`（確定）
- **manual mode（`turn_detection: null` + 手動 commit）があり、現行のクライアント VAD + 手動 commit 設計と同型**。manual mode の累積音声上限 60 秒 = 現行の 60 秒強制終端と同値
- 入力は **pcm/opus の 8/16kHz**。現行の送信フォーマット（OpenAI live 向け 24kHz）からダウンサンプルが必要（実装時に確認）
- `input_audio_transcription.language: "en"` で英語固定可（現行の言語誤判定対策と同等の手当てができる）
- 出典: https://www.alibabacloud.com/help/en/model-studio/qwen-asr-realtime-interaction-process / https://www.alibabacloud.com/help/en/model-studio/real-time-speech-recognition-user-guide

## 対応方針

### Phase 1: Mac 上での疎通・品質・レイテンシ検証（scratchpad スクリプト）

コードはアプリに入れず、scratchpad の node スクリプトで実施。SG 無料枠を使う。

- **TTS**: WS 接続 → commit モードで会話 1 ターン相当の英文（2〜3 文）を文単位に合成
  - 文単位 TTFB（append+commit → 最初の audio.delta）を各 3 回以上計測し、現行 Gemini Flash TTS と並べる
  - 現行の `SentenceTTSClient` は**文ごとに独立した HTTP リクエスト**（stateless struct）なので、(a) WS 接続を文ごとに張る場合の接続オーバーヘッド、(b) WS を張りっぱなしで commit を文単位に繰り返す場合（接続の再利用が仕様上可能）、(c) 非リアルタイム版 `qwen3-tts-flash`（HTTP）のストリーミング、の 3 形を比べてどれで組み込むか決める
  - 英語向け voice 数種で同一英文の wav を生成し、**聞き比べはユーザーが行う**（Chobi / Naruko の 2 キャラ分の声を選べるかも確認）
  - 料金ページで単価・無料枠の最新値を再確認する
- **ASR**: 英語発話の wav（既存録音 or `say` / TTS 生成音声 + 実発話系のサンプル）を manual mode で流す
  - `dashscope-intl` ドメインで接続できるか確認。不可ならワークスペース専用ドメインを使う（WorkspaceId の取得はユーザー作業の可能性あり）
  - partial の刻み・commit → 確定テキストまでの時間・精度（STT らしい崩れ方か）を gpt-live-transcribe と比較
  - 16kHz 制約の確認（24kHz を送るとどうなるか / ダウンサンプル前提の確認）
- 判断基準: 品質が明確に劣る・レイテンシが現行より体感で悪化する場合はここで打ち切り（アプリに組み込まない）

### Phase 2: アプリ組み込み（切替可能な実装の追加）

Phase 1 通過後。既存のプロトコル境界に差し替え実装を追加し、**既定は現行のまま**起動引数で切替可能にする。

- `SentenceTTSClient`（`Voice/CloudPipeline/SentenceTTSClient.swift`）準拠の Qwen TTS クライアント。出力 24kHz PCM16 LE は現行と同一なので `PCMChunkAssembler` / `StreamingAudioPlayer` はそのまま。`TTSProvider` に `.qwen` を追加し `TurnBasedVoiceSession` のファクトリ（`:177-186`）と `-tts-provider` 起動引数に配線
- `StreamingSpeechTranscriber`（`Voice/CloudPipeline/OpenAITranscriptionProtocol.swift:261`）準拠の Qwen ASR クライアント（manual mode = `turn_detection: null` + 手動 commit。現行のクライアント VAD + 送信ゲート + 手動 commit フローをそのまま使う）。イベント名も OpenAI Realtime とほぼ同型なので `OpenAITranscriptionStream` を雛形にできる
  - 注意: 送信フォーマットは現行 24kHz 固定（`TurnBasedVoiceSession.micFormat`）だが Qwen ASR は 8/16kHz のみ。`micFormat` をトランスクライバ側の要求値にする形で 16kHz 化する（リサンプルは既存の `AudioTapRouter.convert` の AVAudioConverter がそのまま担う）
- 切替機構は既存の `-stt-model` / `-tts-provider`（`Support/DebugLaunchArguments.swift`）の流儀に合わせる
- Keychain seed: `-seed-dashscope-key` を `run-install-iphone.sh` / `run-simulator.sh` に追加
- シミュレータでビルド + 動作確認まで

### Phase 3: 実機検証（ユーザー）

- 実機で Qwen TTS / ASR に切り替えて実セッションを行い、以下を確認:
  - TTS: 英語の自然さ・キャラ声の合い方・文単位再生の途切れ感
  - ASR: 認識精度（実マイク・実環境）・ターン制フロー（ジングル・終端検知・60 秒上限）が壊れないか
  - レイテンシ体感（発話終了 → AI 応答開始、文確定 → 読み上げ開始）
- TTS / ASR は独立に採否を決められる（片方だけ採用もあり）

### Phase 4: 判断とまとめ

- 採用 / 見送りを経路ごと（TTS / STT）に決め、結論と根拠をこのプランに記録する
- 採用する場合の後続作業（別タスク or このタスク内で完了）: 既定切替、`Usage/AIPricing.swift` 単価表・`docs/specs/ai-cost-map.md` 更新、旧経路の扱い決め
- 見送りの場合: 追加した切替実装を残すか消すか決める

## Phase 1 実施記録（2026-08-01）: Mac 上の疎通・レイテンシ検証 → **両モデルとも通過（残: ユーザー実聴）**

scratchpad `phase1/` の node スクリプトで実施（`qwen-tts.mjs` / `gemini-tts.mjs` / `qwen-asr.mjs` / `qwen-asr-multi.mjs` / `openai-stt.mjs`）。アプリのコードは変更していない。

### TTS（qwen3-tts-flash-realtime）

- **疎通 OK**: `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen3-tts-flash-realtime`、`Authorization: bearer`。commit モード + `language_type: English` + pcm/24kHz（この組は仕様上も pcm/24k のみ）
- **レイテンシ（文単位 TTFB = commit → 最初の audio.delta、日本から SG）**:

| 経路 | TTFB 中央値 | 備考 |
| --- | --- | --- |
| 現行 Gemini Flash TTS（本番同一リクエスト、6 回） | **840ms** | 769〜915ms |
| Qwen（WS 接続済み、13 回超） | **390ms** | 333〜500ms。WS 接続自体は 750〜900ms（セッション冒頭 1 回） |

- **1 接続で複数文の commit を繰り返せる**（2 文連続で確認）→ ターン/セッション単位で WS を張りっぱなしにすれば毎文 ~390ms。文ごとに接続し直しても計 ~1.2 秒で現行よりわずかに遅い程度
- 出力は 24kHz PCM16 LE で現行と同一（`StreamingAudioPlayer` にそのまま流せる）
- **voice 8 種のサンプル生成済み**（Cherry / Jennifer / Katerina / Serena / Chelsie / Ethan / Ryan / Nofish + 現行 Gemini の Leda / Aoede 比較用）→ ユーザー実聴待ち
- スタイル指示は base モデルでは不可（speech_rate 等のパラメータも非対応）。**instruct 変種 `qwen3-tts-instruct-flash-realtime` なら `instructions` で指示可**（Cherry / Serena で動作確認、TTFB ~480ms とやや増）。ただし **Jennifer では audio が一切返らず無応答**になる相性問題あり。instruct 変種の単価は未確認
- 消費は無料枠内（TTS 11 万字 / 90 日、SG リージョン）

### ASR（qwen3-asr-flash-realtime）

- **疎通 OK**: ドキュメントはワークスペース専用ドメインのみ記載だが、**`dashscope-intl.aliyuncs.com` ドメインでそのまま接続できた**（WorkspaceId 不要）
- **manual mode（`turn_detection: null` + `input_audio_buffer.commit`）が現行フローと同型で動作**。1 接続でセグメント（commit）を跨いだ再利用も OK
- **入力は 16kHz だけでなく `sample_rate: 24000` も実測で通った**（ドキュメント上は pcm 8/16kHz。24k はドキュメント外挙動なので採用時は 16k へのダウンサンプルが安全側、24k 直送は要リスク判断）
- `input_audio_transcription.language: "en"` で英語固定可
- **レイテンシ（commit → completed = 発話終端検知後の確定待ち、リアルタイム送りで計測)**:

| 経路 | 中央値 | 備考 |
| --- | --- | --- |
| 現行 gpt-live-transcribe（本番同一 session.update、3 回） | **754ms** | 597〜792ms |
| Qwen（7 回） | **399ms** | 352〜829ms（1 回だけ 829ms、他は 350〜430ms） |

- **精度**: 合成音声 2 種（say / Qwen TTS 音源）で全回完全一致。学習者の文法誤り（"I go to" / "we eat ramen"）を訂正せず忠実に書き起こす（この用途で必須の性質）。partial は途中 2 秒程度まとめて届く波があるが、確定は commit 後即返る
- `completed` イベントに `usage: {duration 秒 + input/output トークン}` が両建てで入っており、現行 `STTSegmentUsage`（duration 型 / tokens 型両対応）の枠にそのまま載る
- 消費は無料枠内（ASR 10 時間 / 90 日）

### 生成サンプル（実聴用。[assets/alibaba-voice-models/](assets/alibaba-voice-models/) にコミット済み・計 5.2MB）

**TTS のテキスト**（Qwen 全 voice 共通。会話 1 ターン相当の 2 文を文単位に commit したものの連結。1 文目が Chobi 想定・2 文目が Naruko 想定の発話）:

1. `That sounds like a great weekend! Did you go anywhere special with your family?`
2. `Oh, I love ramen too! What kind of toppings do you usually get?`

**現行（基準。本番と同一のスタイル指示付き。こちらは各キャラの 1 文のみ）**:

| ファイル | 内容 |
| --- | --- |
| [gemini-Leda.wav](assets/alibaba-voice-models/gemini-Leda.wav) | 現行 Chobi（Leda）。上の 1 文目 |
| [gemini-Aoede.wav](assets/alibaba-voice-models/gemini-Aoede.wav) | 現行 Naruko（Aoede）。上の 2 文目 |

**Qwen base（qwen3-tts-flash-realtime。スタイル指示は指定不可、voice 素のまま）**:

| ファイル | voice | 傾向 |
| --- | --- | --- |
| [qwen-Cherry.wav](assets/alibaba-voice-models/qwen-Cherry.wav) | Cherry | 女声。実装の暫定 Chobi |
| [qwen-Serena.wav](assets/alibaba-voice-models/qwen-Serena.wav) | Serena | 女声。実装の暫定 Naruko |
| [qwen-Jennifer.wav](assets/alibaba-voice-models/qwen-Jennifer.wav) | Jennifer | 女声 |
| [qwen-Katerina.wav](assets/alibaba-voice-models/qwen-Katerina.wav) | Katerina | 女声 |
| [qwen-Chelsie.wav](assets/alibaba-voice-models/qwen-Chelsie.wav) | Chelsie | 女声 |
| [qwen-Ethan.wav](assets/alibaba-voice-models/qwen-Ethan.wav) | Ethan | 男声 |
| [qwen-Ryan.wav](assets/alibaba-voice-models/qwen-Ryan.wav) | Ryan | 男声 |
| [qwen-Nofish.wav](assets/alibaba-voice-models/qwen-Nofish.wav) | Nofish | 男声 |

**Qwen instruct 変種（qwen3-tts-instruct-flash-realtime。`instructions` でスタイル指示可。TTFB は +90ms 程度・単価未確認）**:

| ファイル | voice + 指示 |
| --- | --- |
| [qwen-Cherry-instruct-chobi.wav](assets/alibaba-voice-models/qwen-Cherry-instruct-chobi.wav) | Cherry + Chobi 指示 |
| [qwen-Cherry-instruct-naruko.wav](assets/alibaba-voice-models/qwen-Cherry-instruct-naruko.wav) | Cherry + Naruko 指示 |
| [qwen-Serena-instruct-naruko.wav](assets/alibaba-voice-models/qwen-Serena-instruct-naruko.wav) | Serena + Naruko 指示 |

- Chobi 指示: `Speak in a warm, lively, gently cheerful voice, like a friendly teacher chatting with a student. Speak at a brisk, natural conversational pace, without dragging out words.`（本番 styleInstruction と同旨）
- Naruko 指示: `Speak in a bright, energetic voice, full of curiosity, like an enthusiastic student chatting with friends.`
- Jennifer は instruct 変種だと音声が一切返らず生成不可（相性問題。Phase 1 本文参照）

**ASR のテスト音声と結果**:

- 入力音声: [say-learner.wav](assets/alibaba-voice-models/say-learner.wav)（macOS `say` Samantha・16kHz。学習者らしい文法誤り入り）
- 原文: `Last weekend I go to Yokohama with my family, and we eat ramen. It was very delicious, so I want to go again.`
- Qwen 確定: `Last weekend I go to Yokohama with my family and we eat ramen. It was very delicious, so I want to go again.`（誤りを訂正せず忠実。カンマの有無だけ揺れ）
- 現行 gpt-live-transcribe 確定: `Last weekend I go to Yokohama with my family, and we eat ramen. It was very delicious. So I want to go again.`（同等。文の切り方だけ揺れ）
- ほかに qwen-Cherry.wav / gemini-Leda.wav を 16kHz へ落とした音源でも Qwen は全回同一の正しい書き起こしを返した

### 残作業（Phase 1 完了条件）

- [ ] **ユーザー実聴**: 上の生成サンプルを聞き比べ（現行 Gemini Leda / Aoede と比較して Chobi / Naruko の voice を仮決め。base か instruct 変種かもここで判断）
- 単価は cheap-chinese-ai-models Phase 1（2026-07-31 に公式料金ページで確認済み: TTS $0.13/1 万字・ASR $0.000090/秒）から変化がない前提。採用決定時に再確認する

## Phase 2 実施記録（2026-08-01）: アプリ組み込み（切替可能・既定は現行のまま）

**既定挙動は一切変えていない**（TTS 既定 Gemini / STT 既定 gpt-live-transcribe のまま）。切替は DEBUG 起動引数のみ。

- 追加ファイル:
  - `Voice/CloudPipeline/QwenTranscriptionStream.swift` — `StreamingSpeechTranscriber` 準拠。manual mode（`turn_detection: null` + 手動 commit）で現行のクライアント VAD フローをそのまま使う。`OpenAITranscriptionStream` と同構造（直列 sendQueue / 15 秒 ping / 使い捨て）。**Qwen は `input_audio_buffer.clear` 非対応（実測 invalid_value）のため、clearClientBuffer は「commit して結果を読み捨てる」FIFO で代替**（破棄セグメントも append 分は課金されるので usage だけ流す）
  - `Voice/CloudPipeline/QwenTTSClient.swift` — `SentenceTTSClient` 準拠。**WS を voice ごとに張りっぱなしにして文単位 commit を繰り返す**（voice は接続の最初の session.update でしか設定できないため 2 キャラ = 2 接続）。アイドル切断は張り直して 1 回だけ再試行、barge-in で中断した接続は破棄。voice 写像は `SpeechStyle.voice`（Gemini 名）→ Qwen 名（暫定 Leda→Cherry / Aoede→Serena、実聴後に調整)
- 変更点: `TTSProvider.qwen` 追加、`AIUsageEvent.Provider.alibaba` 追加、`AIPricing` に alibaba 分岐（ASR $0.000090/秒、TTS $0.13/1 万字。TTS の課金文字数は `response.done` の `usage.characters` を `TTSUsage.inputTokens` に載せて運ぶ）+ 料金表 2 行、`OpenAITranscriptionConfiguration` に `isQwenASR` / `usesClientEndpointing` / `micSampleRate`（Qwen は 16kHz、リサンプルは既存 `AudioTapRouter.convert`）、`TurnBasedVoiceSession` に dashScopeKeyProvider + 接続分岐 + micFormat の可変化、Keychain `dashscope-api-key` + `-seed-dashscope-key` + run スクリプト 2 本
- 切替方法（実機検証 Phase 3 で使う）:
  - TTS: `./run-install-iphone.sh -tts-provider qwen`（voice 差し替え: `-qwen-voice-chobi Cherry -qwen-voice-naruko Serena`）
  - STT: `-stt-model qwen3-asr-flash-realtime`
  - 両方: `./run-install-iphone.sh -tts-provider qwen -stt-model qwen3-asr-flash-realtime`
- テスト: `QwenVoicePipelineTests`（モデル選択フラグ / session.update 形 / partial の text+stash 連結 / usage パース / エラー分類 / voice 写像 / alibaba 料金）を追加。**全テストスイート成功・ビルド成功**
- シミュレータ E2E（`./run-simulator.sh -tts-provider qwen -stt-model qwen3-asr-flash-realtime -start-conversation -send-text ... -send-text "Goodbye..."`）: 会話 2 ターン → [end] → フィードバック生成 → 次トピック提示まで完走。SwiftData の使用量レコードに **provider=alibaba / qwen3-tts-flash-realtime の TTS 7 件（課金 416 文字・音声 16.3 秒・推定 $0.0054）** が記録され、単価計算（$0.13/1 万字）とも一致。STT はシミュレータにマイクが無いため接続までで、音声パスは Phase 3 の実機で確認する

## 影響範囲

- Phase 1 はアプリのコード変更なし（scratchpad のみ）
- Phase 2 以降: 音声レイヤに差し替え実装を追加（既定挙動は変えない）。`project.yml` / run スクリプト / Keychain seed に dashscope キー追加

## テスト方針

- Phase 1: レイテンシは各 3 回以上計測して中央値。TTS 品質は同一英文でユーザー実聴、ASR 精度は同一音源で現行と突き合わせ
- Phase 2: `xcodebuild` でビルド確認 + シミュレータで会話フロー一巡（切替あり / なし両方）
- Phase 3: 実機での実セッション。実機未確認項目が残る場合は明示する
