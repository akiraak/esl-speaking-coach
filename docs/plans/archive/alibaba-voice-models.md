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

- **最終比較は 4 案で並べる**（2026-08-01 ユーザー指示）: 現行 / **STT のみ Qwen** / **TTS のみ Qwen** / 両方 Qwen。それぞれ 1 セッション・月額（毎日 1 セッション想定）を [ai-cost-map.md](../specs/ai-cost-map.md) の概算例ベースで出す（TTS / STT は独立に採否を決められるため）
- instruct 変種（採用構成）の単価を Model Studio コンソールで確認し、`AIPricing` の暫定値（base と同額）の正誤を確定する
- 採用 / 見送りを経路ごと（TTS / STT）に決め、結論と根拠をこのプランに記録する
- 採用する場合の後続作業（別タスク or このタスク内で完了）: 既定切替、`Usage/AIPricing.swift` 単価表・`docs/specs/ai-cost-map.md` 更新、旧経路の扱い決め
- 見送りの場合: 追加した切替実装を残すか消すか決める

### Phase 5: アプリ内の料金表・料金計算の検証（2026-08-01 追加）

採用構成での課金の見え方が正しいことを確認してから締める。

- 管理画面「料金」タブの単価表（`AIPricing.rateTable()` 生成）に alibaba（Qwen TTS / ASR）の行が正しく表示されるか、単価が Phase 4 の確認値と一致するか
- 使用量レコードの推定額計算（`qwenTTSCost` / `qwenASRCost`。instruct 変種のモデル名でも正しく計算されるか）を、実セッションのレコードと手計算の突き合わせで検証する
- 会話画面のセッション料金表示など、料金を表示する他の画面があれば同様に確認する

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
| [qwen-Serena-instruct-chobi.wav](assets/alibaba-voice-models/qwen-Serena-instruct-chobi.wav) | Serena + Chobi 指示（Phase 3.5 で追加） |
| [qwen-Serena-instruct-naruko.wav](assets/alibaba-voice-models/qwen-Serena-instruct-naruko.wav) | Serena + Naruko 指示 |
| [qwen-Chelsie-instruct-chobi.wav](assets/alibaba-voice-models/qwen-Chelsie-instruct-chobi.wav) | Chelsie + Chobi 指示（Phase 3.5 で追加） |
| [qwen-Chelsie-instruct-naruko.wav](assets/alibaba-voice-models/qwen-Chelsie-instruct-naruko.wav) | Chelsie + Naruko 指示（Phase 3.5 で追加） |

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

## Phase 3 実施記録（2026-08-01）: 実機検証 → **ASR 通過 / TTS は voice のキャラ合わせが必要**

`./run-install-iphone.sh -tts-provider qwen -stt-model qwen3-asr-flash-realtime` で実機に切替インストールし、実セッションで確認した（ユーザー実施）。

- **ASR（qwen3-asr-flash-realtime）: 問題なし**。実マイクでの認識精度・ターン制フロー（ジングル / 終端検知）とも現行運用に耐える → **採用候補として通過**
- **TTS（qwen3-tts-flash-realtime）: 動作は問題ないが、暫定 voice（Chobi=Cherry / Naruko=Serena）がキャラクターに合っておらず調整が必要**。base モデルはスタイル指示不可のため、調整手段は (a) 他の base voice への差し替え（`-qwen-voice-chobi` / `-qwen-voice-naruko`、実装済み）、(b) instruct 変種 `qwen3-tts-instruct-flash-realtime` + `instructions` でのスタイル指示（現行 Gemini の styleInstruction と同型。アプリ側は未実装、TTFB +90ms 程度、Jennifer は生成不可の相性問題あり）
- instruct 変種の単価は 2026-08-01 に公開ドキュメント（model-pricing / tts-model / realtime-tts-user-guide）を再確認したが**記載が見つからず未確認のまま**（Model Studio コンソールでの確認が必要）。採用判断に効くので instruct 案を進める場合は先に確認する

### 残作業（Phase 3.5: TTS voice のキャラ合わせ）

方針（2026-08-01 ユーザー決定): **base voice 差し替えと instruct 変種の両方をサンプル生成し、実聴で選ぶ**。

- [x] instruct 変種のサンプルを女声 voice 全種へ拡充（Serena-chobi / Chelsie-chobi / Chelsie-naruko を追加生成。**Katerina は instruct 変種だと無応答で生成不可** — Jennifer と同じ相性問題。instruct 可の女声は Cherry / Serena / Chelsie の 3 種）
- [x] アプリに instruct 変種サポートを追加（`-qwen-tts-instruct` で `qwen3-tts-instruct-flash-realtime` へ切替。スタイル指示は `QwenTTSConfiguration.instructionMap`（Phase 1 と同文）を既定に、`-qwen-instruct-chobi` / `-qwen-instruct-naruko` でリビルドなしに差し替え可。接続プールのキーは voice + 指示にして、同一 voice を両キャラで聞き比べても接続が混ざらないようにした。instruct 変種の単価は未確認のため `AIPricing` は暫定で base と同額扱い）
- [x] シミュレータ E2E（`-tts-provider qwen -qwen-tts-instruct` で会話 2 ターン → フィードバックまで完走。使用量レコードに `qwen3-tts-instruct-flash-realtime` の TTS 6 件・課金 387 文字・音声 11.4 秒を確認）。全テストスイート成功
- [x] 実聴ラウンド 1（2026-08-01）: **Chobi = Serena 系で喋り方のバリエーションを出して選ぶ / Naruko = Jennifer 希望**
  - Serena × Chobi 指示のバリエーション 3 種を追加生成（calm / upbeat / casual。既定の warm-brisk と合わせ 4 択）
  - **Jennifer は instruct モデル系で正式非対応と確定**（realtime は無応答、HTTP 版は "Voice 'Jennifer' is not supported"、公式 voice list の instruct 対応欄にも無い）→ Jennifer を使うなら base 素のまま（スタイル指示不可）
  - instruct 対応で未実聴の女声（Momo / Bella / Vivian。公式説明が Naruko 系の「明るい・元気」寄り）の base + Naruko 指示サンプルを追加生成し、Jennifer base との比較候補にする
- [x] 実聴ラウンド 2（2026-08-01）: **Chobi = Serena × casual 指示で確定**。Naruko は Jennifer を諦め **Vivian に決定**（喋り方は選定中）
  - アプリの既定値を反映済み: `voiceMap` = Leda→Serena / Aoede→Vivian、Chobi の指示 = casual（テストも更新、成功）
  - Vivian × Naruko 指示のバリエーション 3 種を追加生成（playful / confident / soft。既定の bright-energetic と合わせ 4 択）
- [x] 実聴ラウンド 3（2026-08-01）: **Naruko = Vivian × bright（既定の bright-energetic 指示）で確定**。アプリ既定は反映済みだったため注記のみ更新
- [x] 決めた組み合わせ（**Chobi = Serena × casual / Naruko = Vivian × bright、instruct 変種**）での実機再確認（2026-08-01 完了）
  - 実機セッションで「2 キャラの声の違いを感じにくい」との指摘 → シミュレータ実セッション + 診断ログ（`Qwen TTS: voice=...` を文ごとに記録するログを追加）で **キャラごとに正しい voice / 指示で合成されていることを実測確認**（Naruko 文=Vivian+instruct / Chobi 文=Serena+instruct、接続も 2 本別々）。配線のバグではなく声質が近いだけと判明
  - 同組み合わせの掛け合い音声（duet-serena-casual-vivian-bright.wav、scratchpad 生成）をユーザー実聴 → **問題なしと判断、この組み合わせで確定**

**Phase 3.5 完了。** 残りは Phase 4（採否判断とまとめ。instruct 変種の単価をコンソールで確認 → `AIPricing` 暫定値の正誤確認を含む）。

**ラウンド 2 の生成サンプル**（[assets/alibaba-voice-models/](assets/alibaba-voice-models/) に追加。テキストは Phase 1 と同一の 2 文）:

| ファイル | 内容 |
| --- | --- |
| qwen-Serena-instruct-chobi-calm.wav | Serena + Chobi 指示 calm（穏やか・急かさない） |
| qwen-Serena-instruct-chobi-upbeat.wav | Serena + Chobi 指示 upbeat（明るく励ます・速め） |
| qwen-Serena-instruct-chobi-casual.wav | Serena + Chobi 指示 casual（くだけた雑談調） |
| qwen-Momo.wav / qwen-Momo-instruct-naruko.wav | Momo（公式: playful and mischievous）素 / Naruko 指示 |
| qwen-Bella.wav / qwen-Bella-instruct-naruko.wav | Bella（公式: playful, bubbly, mischievous）素 / Naruko 指示 |
| qwen-Vivian.wav / qwen-Vivian-instruct-naruko.wav | Vivian（公式: confident, cute, slightly feisty）素 / Naruko 指示 |
| qwen-Vivian-instruct-naruko-playful.wav | Vivian + Naruko 指示 playful（はしゃぎ気味・弾む）（ラウンド 3） |
| qwen-Vivian-instruct-naruko-confident.wav | Vivian + Naruko 指示 confident（生意気・元気）（ラウンド 3） |
| qwen-Vivian-instruct-naruko-soft.wav | Vivian + Naruko 指示 soft（やわらか・おっとり）（ラウンド 3） |

## Phase 4 実施記録（2026-08-01 着手）: 最終比較

### 4 案のコスト比較（1 セッション / 月額）

前提は [ai-cost-map.md](../specs/ai-cost-map.md) の概算例と同一（15 分 / 30 ターン / ユーザー発話 5 分 / AI 生成音声 5 分、毎日 1 セッション = 月 30 回）。「その他」= 会話 LLM + フィードバック + トピック生成 = $0.28/セッション（切替の影響なし）。

| 構成 | STT | TTS | その他 | 合計 / セッション | 月額 | 現行比の節約 / 月 |
| --- | --- | --- | --- | --- | --- | --- |
| 現行（gpt-live + Gemini TTS） | $0.085 | $0.150 | $0.28 | **$0.52** | 約 $15.5 | — |
| **STT のみ Qwen** | $0.027 | $0.150 | $0.28 | **$0.46** | 約 $13.7 | **約 $1.7** |
| **TTS のみ Qwen** | $0.085 | $0.049 | $0.28 | **$0.41** | 約 $12.4 | **約 $3.0** |
| 両方 Qwen | $0.027 | $0.049 | $0.28 | **$0.36** | 約 $10.7 | **約 $4.8** |

- 単価: STT は gpt-live $0.017/分 → Qwen $0.0054/分（$0.000090/秒）で約 1/3。TTS は Gemini ≈ $0.03/分 → Qwen ≈ $0.0098/分（$0.13/1 万字を実測話速で換算）で約 1/3
- ⚠️ **TTS の Qwen 単価は base モデルの確認値**。採用構成は instruct 変種（Chobi=Serena×casual / Naruko=Vivian×bright）のため、**instruct の単価がコンソールで base と同額と確認できることがこの表の前提**。異なればここと `AIPricing` を更新して再計算する
- 品質・レイテンシ面は Phase 1〜3.5 で確認済み: ASR は精度・フロー問題なし（確定レイテンシは実測で現行より速い）、TTS は voice 選定済みで文単位 TTFB も現行 Gemini より速い（instruct でも +90ms 程度）

### 採否決定

- **STT: 見送り（2026-08-01 ユーザー決定）**。既定の gpt-live-transcribe を維持する（もともと既定は変えていないので、実機の起動引数から `-stt-model qwen3-asr-flash-realtime` を外すだけ）。Qwen ASR の切替実装は gpt-4o-transcribe 旧経路と同様に**残す**（起動引数でのみ有効・既定に影響なし。掃除するなら別タスク）
- **TTS: 採用（2026-08-01）**。「TTS のみ Qwen」案（月 約 $3.0 節約）で確定し、既定を切り替えた:
  - `TurnBasedVoiceSession.Configuration.ttsProvider` の既定を `.gemini` → `.qwen` に、`QwenTTSConfiguration.model` の既定を instruct 変種に変更（旧既定へは `-tts-provider gemini` か既定値 1 箇所で戻せる。`-qwen-tts-instruct` は不要になったが互換のため残置）
  - `AIPricing.rateTable()` を更新（Qwen instruct を TTS 既定行に、Gemini を切替用へ、Qwen ASR は「切替用・見送り」表記）。`CLAUDE.md`（技術スタック / 音声レイヤ表 / セキュリティ）と `docs/specs/ai-cost-map.md`（サマリ・単価表・TTS 詳細・概算例 約 $0.52 → **約 $0.42**、月 $16 → **$12.5 前後**・記録取得元・注意 1 番）も採用構成へ更新
  - ⚠️ **instruct 変種の単価は未公表のため base と同額（$0.13/1 万字）の暫定計上**。国際版の公開ドキュメント（model-pricing / models / TTS 各ページ・中国語版含む）を再確認したが記載なし。コンソールか初回請求で確認し、違ったら `AIPricing` / コスト表を更新する（TODO に残す）

## Phase 5 実施記録（2026-08-01）: アプリ内の料金表・料金計算の検証 → **問題なし**

- **単価表**（管理画面「料金」タブ、`AIPricing.rateTable()` 生成）: 行構成と表記をユニットテストで固定（`qwen3-tts-instruct-flash-realtime` が「TTS（既定）」、Gemini は「切替用の旧既定」、`qwen3-asr-flash-realtime` は「切替用。検証の結果見送り」）。料金タブの表示もシミュレータで確認（累計・種別内訳・日別に反映）
- **推定額計算**: 切替フラグなしの既定起動でシミュレータ実セッションを流し、`qwen3-tts-instruct-flash-realtime` のレコードが増えることを確認（= 既定切替が有効）。instruct 累計 12 件・課金 860 文字の推定額 **$0.01118 = 手計算（860 / 10,000 × $0.13）と完全一致**。base 分（416 文字 → $0.005408）も一致
- 全テストスイート成功。instruct 変種の単価だけ暫定（base と同額）のため、確定は TODO の別項目で追跡する

## 影響範囲

- Phase 1 はアプリのコード変更なし（scratchpad のみ）
- Phase 2 以降: 音声レイヤに差し替え実装を追加（既定挙動は変えない）。`project.yml` / run スクリプト / Keychain seed に dashscope キー追加

## テスト方針

- Phase 1: レイテンシは各 3 回以上計測して中央値。TTS 品質は同一英文でユーザー実聴、ASR 精度は同一音源で現行と突き合わせ
- Phase 2: `xcodebuild` でビルド確認 + シミュレータで会話フロー一巡（切替あり / なし両方）
- Phase 3: 実機での実セッション。実機未確認項目が残る場合は明示する
