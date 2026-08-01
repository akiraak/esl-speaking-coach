# AI 利用料金マップ（どの操作でどの API に課金が発生するか）

2026-07-25 作成。本アプリはバックエンドなしで 4 プロバイダ（Anthropic / OpenAI / Google Gemini / Alibaba）の API をアプリから直叩きするため、課金が発生する箇所をここに集約する。将来の「管理画面（AI 利用料金）」タスクの土台でもある。

- 単価は **2026-07-25 時点**の各社公表値（Alibaba は 2026-07-31 確認）。変動前提で、実装時は必ず最新の料金ページを確認する
  - Anthropic: https://platform.claude.com/docs/en/pricing
  - OpenAI: https://platform.openai.com/pricing
  - Gemini: https://ai.google.dev/gemini-api/docs/pricing
  - Alibaba (Model Studio 国際版): https://www.alibabacloud.com/help/en/model-studio/model-pricing（TTS / ASR の単価はモデル別ドキュメント・コンソール側）
- 「実装状況」は 2026-07-25 時点。未実装のものは仕様（[conversation-design.md](conversation-design.md)）ベースで記載する

## 課金マップ（サマリ）

| # | 操作 | API / モデル | 課金単位 | 発生タイミング | 実装状況 |
| --- | --- | --- | --- | --- | --- |
| 1 | 発話の文字起こし（STT） | OpenAI Realtime transcription / `gpt-live-transcribe`（2026-07-31 採用） | **ユーザーが実際に話した音声の長さ**（クライアント VAD が切り出した発話セグメント + 遡り 0.5 秒だけを送信・commit する。無音・待機中は送らないので課金されない。セグメントごと秒単位切り上げ） | 会話セッション中、ユーザーが話すたび | 実装済み |
| 2 | 会話ターン生成（LLM） | Claude Messages / `claude-sonnet-5` | 入力トークン + 出力トークン（**毎ターン履歴全体を再送**） | ユーザー発話が確定するたび 1 回 | 実装済み |
| 3 | 読み上げ（TTS） | Alibaba `qwen3-tts-instruct-flash-realtime`（2026-08-01 採用） | **課金文字数**（$0.13 / 1 万字。`usage.characters`） | AI 発話の **1 文ごと**に WebSocket へ commit | 実装済み |
| 4 | トピック候補生成 | Claude Messages / `claude-sonnet-5` | 入力 + 出力トークン(少量) | 初回起動時 / セッション終了直後 / 「🔄 他の候補」タップ時 | 実装済み |
| 5 | セッション後フィードバック生成 | Claude Messages / `claude-sonnet-5`（2026-07-31 に opus-5 から変更） | 入力（会話全文）+ 出力トークン（effort high・max_tokens 16000） | セッション正常終了ごとに 1 回（学習者の発話 2 未満はスキップ。失敗時のリトライも課金） | 実装済み |
| 6 | 記憶ノート更新 | Claude Messages / `claude-sonnet-5` | 入力（前回ノート + 会話全文）+ 出力トークン（max_tokens 2000） | セッション正常終了ごとに 1 回（学習者の発話 2 未満はスキップ。失敗してもリトライ導線なし） | 実装済み |
| 7 | 会話の翻訳 | Claude Messages / `claude-haiku-4-5` | 入力（トピック + 直前 8 発話の文脈 + 対象発話）+ 出力トークン（日本語訳のみ） | **訳の表示が ON のときだけ**。ターン終了ごと + セッション終了時 + OFF → ON にした時 + 訳 ON のまま起動した時 | 実装済み |

## 単価表（2026-07-25 時点）

| API | 単価 | 目安に直すと |
| --- | --- | --- |
| OpenAI `gpt-live-transcribe`（STT・既定） | セッション音声 $0.017 / 分（usage は duration 型・セグメントごと秒単位切り上げ） | ユーザーが 10 分話して約 $0.17。認識精度向上と引き換えに旧既定の約 3 倍（[採用記録](../plans/archive/gpt-live-transcribe-adoption.md)） |
| （参考）OpenAI `gpt-4o-transcribe`（STT。`-stt-model` で戻せる旧既定） | 約 $0.006 / 音声 1 分 | ユーザーが 10 分話して約 $0.06 |
| Alibaba `qwen3-tts-instruct-flash-realtime`（TTS・既定。2026-08-01 採用） | $0.13 / 1 万文字（instruct の単価は未公表のため base `qwen3-tts-flash-realtime` の 2026-07-31 確認値を暫定計上。コンソール / 初回請求で要確認） | **生成音声 1 分 ≈ $0.0098**（実測話速換算。旧既定 Gemini の約 1/3） |
| （参考）Alibaba `qwen3-asr-flash-realtime`（STT 切替用。検証の結果見送り） | 音声 $0.000090 / 秒 | 1 分 ≈ $0.0054 |
| （参考）Gemini 3.1 Flash TTS preview（TTS 切替用の旧既定） | 入力 $1 / 1M トークン、音声出力 $20 / 1M トークン（25 トークン/秒） | 生成音声 1 分 ≈ $0.03（1,500 トークン） |
| （参考）Gemini 2.5 Flash TTS preview | 入力 $0.50 / 1M、出力 $10 / 1M | 生成音声 1 分 ≈ $0.015（3.1 の半額） |
| （参考）OpenAI `gpt-4o-mini-tts`（切替用） | 音声 1 分 ≈ $0.015（参考値・要再確認） | — |
| Claude `claude-sonnet-5` | 入力 $3 / 出力 $15 / 1M トークン（〜2026-08-31 は導入価格 $2 / $10） | — |
| （参考）Claude `claude-opus-5`（〜2026-07-31 のフィードバック生成。現在は未使用） | 入力 $5 / 出力 $25 / 1M トークン | — |
| Claude プロンプトキャッシュ | 書き込み 1.25 倍（5 分 TTL）、読み込み 0.1 倍 | system prompt（約 2,000 トークン）は 2 ターン目以降ほぼタダ |

## 各操作の詳細

### 1. STT（発話の文字起こし）

- 実装: `Voice/CloudPipeline/OpenAITranscriptionStream.swift` + `OpenAITranscriptionProtocol.swift` + `Voice/ClientSpeechEndpointer.swift`（クライアント VAD）+ `Voice/MicrophoneCapture.swift`（送信ゲート）
- セッション開始時に WebSocket（`wss://api.openai.com/v1/realtime?intent=transcription`）を張る。既定の `gpt-live-transcribe` はサーバ VAD 非対応のため、クライアント VAD が判定した**発話区間 + 遡り 0.5 秒だけ**を append し、終端で手動 commit する。**無音や AI の発話待ち時間はそもそも送らないので課金されない**（「アプリを開いている時間」ではなく「ユーザーが話した時間」に比例する）
- 課金は commit した音声の長さ（セグメントごと秒単位切り上げ）。細切れ commit は切り上げのぶんコスト効率が落ちる。エネルギー VAD が終端を出せない持続環境音対策に 60 秒で強制終端するフェイルセーフあり（課金の無制限伸長を防ぐ）
- 旧既定 `gpt-4o-transcribe`（`-stt-model` で切替）はマイク音声をセッション中ずっと流し、サーバ VAD が切り出したセグメントのみ課金される（挙動は従来どおり）
- シミュレータではマイク無効のため STT 課金はゼロ（接続だけでは課金されない）

### 2. 会話ターン生成（Claude）

- 実装: `Claude/ClaudeMessagesClient.swift`、呼び出し元 `Voice/TurnBasedVoiceSession.swift`
- ユーザー発話 1 回につき 1 リクエスト（ストリーミング、max_tokens 1024、effort low）。台本方式なので 2 キャラ分でも呼び出しは 1 回
- **コスト構造上の最重要ポイント: API はステートレスで、毎ターン会話履歴全体を再送する**
  - 入力トークンはターンが進むほど増える（履歴は 1 ターンあたり実測 50〜110 出力トークン + ユーザー発話分ずつ成長）
  - セッション累計の入力コストはターン数に対しておおよそ **2 乗**で効く。長いセッションほど 1 ターンあたりの単価が上がる
- system prompt（2 キャラ台本・約 2,000 トークン）は `cache_control: ephemeral` 済み。初回のみ 1.25 倍で書き込み、以降のターンは 0.1 倍で読むだけ（TTL 5 分。ターン間隔が 5 分以内なら維持される）。`claude-sonnet-5` のキャッシュ最小プレフィックス 1,024 トークンを満たしている
  - なお **messages（履歴）側にはキャッシュを張っていない**ので、履歴分は毎ターン満額。会話が長くなってコストが気になったら、直近ターン末尾への `cache_control` 追加（履歴分も 0.1 倍で読める）が次の最適化候補
- barge-in で生成途中キャンセルした場合も、生成済みトークン分は課金される

### 3. TTS（読み上げ）

- 実装: `Voice/CloudPipeline/QwenTTSClient.swift` + `CloudSentenceSpeaker.swift`（切替用に `GeminiTTSClient.swift` / `OpenAITTSClient.swift`）
- Claude のストリーミングから文が切り出されるたびに **1 文 = 1 commit**。WebSocket はキャラ（voice + スタイル指示）ごとに張りっぱなしで再利用する（2 キャラ = 2 接続。voice / instructions は接続時の session.update でのみ設定）
- 課金は **commit したテキストの文字数（$0.13 / 1 万字）**。`response.done` の `usage.characters` が課金単位で、Gemini と違い音声出力側の従量は無い。実測話速の換算で **生成音声 1 分 ≈ $0.0098**（旧既定の約 1/3）
- キャラ別スタイル指示（instructions）は接続時に 1 回送るだけで、文ごとの課金文字数には乗らない
- **barge-in 時の注意**: 先読みで取得済み・取得中だった未再生の文も生成された分は課金される（従来どおり）。barge-in で中断した Qwen 接続は応答が残留するため破棄して張り直す
- 旧既定 Gemini 3.1 Flash TTS へは `-tts-provider gemini` か `TurnBasedVoiceSession.Configuration.ttsProvider` の 1 箇所で戻せる（音声出力従量 ≈ $0.03/分）

### 4. トピック候補生成（実装済み）

- 実装: `Claude/TopicSuggestionClient.swift`、呼び出し元 `Conversation/ChatRoomStore.swift`
- 仕様: [conversation-design.md](conversation-design.md) の「トピック生成」。`claude-sonnet-5` / 非ストリーミング / effort low / structured outputs
- 呼び出しタイミングは 3 つ: 初回起動時 / セッション終了直後 / 「🔄 他の候補」タップ時
- 入力（固定 system prompt + 直近トピック一覧）も出力（タイトル + フック × 3 件）も数百トークン規模で、**1 回 $0.01 未満**。連打されても実害が出にくいが、🔄 は課金操作である点は管理画面で見えるようにする

### 5. セッション後フィードバック生成（実装済み）

- 仕様: [session-feedback.md](session-feedback.md)。`claude-sonnet-5` / effort high / max_tokens 16000 / ストリーミング + structured outputs
- 入力に**会話全文**を渡すため、セッションが長いほど入力コストが増える。出力も数千トークン規模になり得る
- 長文入出力のため単発の API 呼び出しとしては高額になりやすい（ただしセッションごとに 1 回だけ）。
  当初は `claude-opus-5` だったが、アプリ内で最も高額な単発呼び出しだったため 2026-07-31 に
  `claude-sonnet-5` へ変更（$5/$25 → $3/$15。`SessionFeedbackClient.model` の 1 箇所で戻せる）

### 7. 会話の翻訳（実装済み）

- 実装: `Claude/TranslationClient.swift`、呼び出し元 `Conversation/ChatRoomStore.swift`
- 仕様: [conversation-design.md](conversation-design.md) の「会話の翻訳」。`claude-haiku-4-5` / 非ストリーミング / structured outputs（`effort` は haiku-4-5 では 400 になるため送らない）
- **訳の表示が OFF のあいだは 1 回も呼ばない**（訳を使わない日は完全に無課金）
- 生成対象は常に 1 セッション分だけ（セッション中は現在のセッション、セッション外はタイムライン末尾のセッション）。それより古いセッションは訳さない
- 1 リクエスト = 最大 20 発話。ターン終了ごとの先行生成では 1〜数発話 + 文脈 8 発話なので**数百トークン規模**、haiku 単価（$1 / $5）なので 1 セッション分でも $0.01 に届かない
- 失敗は best effort（次のターン終了・トグル再 ON で再挑戦。そのぶん再課金される）

## 課金されないもの

- 音声の再生・マイクキャプチャ・VAD 待ち（クライアント処理。STT は発話セグメント分のみ）
- WebSocket / HTTP の接続自体（リクエストを投げるまで課金なし）
- 会話履歴の保存（SwiftData・端末内）、Keychain、UI 全般
- シミュレータでのテキスト入力検証は STT 課金なし（Claude + TTS は通常どおり課金）

## 1 セッションの概算例

前提: 15 分のセッション、30 ターン、ユーザー発話合計 5 分、AI 発話（生成音声）合計 5 分。ターンあたり履歴成長 約 100 トークン、system prompt 2,000 トークン（キャッシュ有効）。

| 項目 | 計算 | 概算 |
| --- | --- | --- |
| STT（ユーザー発話 5 分） | 5 × $0.017 | $0.09 |
| TTS（生成音声 5 分、Qwen instruct） | 5 × $0.0098 | $0.05 |
| 会話 LLM 入力（履歴、平均 1,500 × 30 ターン） | 45K トークン × $3/1M | $0.14 |
| 会話 LLM 入力（キャッシュ済み system、2,000 × 30） | 60K × $0.3/1M + 初回書込 | $0.03 |
| 会話 LLM 出力（約 100 × 30 ターン） | 3K × $15/1M | $0.05 |
| フィードバック生成（sonnet、入力 5K / 出力 3K） | $3/1M × 5K + $15/1M × 3K | $0.06 |
| トピック生成 | — | $0.01 未満 |
| **合計** | | **約 $0.42 / セッション** |

- 毎日 1 セッションで **月 $12.5 前後**が目安（2026-08-01 の Qwen TTS 切替前は TTS $0.15 で 約 $0.52 / 月 $16 前後）
- コストの並びは概ね **会話 LLM ＞ STT ＞ フィードバック ≧ TTS ＞ トピック生成**

## 利用量の記録（2026-07-25 実装）

管理画面「AI 利用料金」のため、6 経路すべてで API レスポンスの usage を記録している
（実装プラン: `docs/plans/archive/history-persistence-and-admin.md`）。

- 取得元: Claude は SSE の `message_start` / `message_delta`（非ストリーミングは応答の `usage`）、
  OpenAI STT は transcription completed イベントの usage（tokens 型 / duration 型両対応）、
  Qwen TTS は `response.done` の `usage.characters`（課金文字数。+ 受信 PCM バイト数からの秒数）、
  Gemini TTS（切替時）は SSE の `usageMetadata`（+ 受信 PCM バイト数からの秒数）
- 記録: `Persistence/UsageStore.swift`（`APIUsageRecord`）。生の usage と、**記録時に** `Usage/AIPricing.swift`
  の単価表（この文書の単価表と対応。sonnet-5 の導入価格切替も考慮）で計算した推定額を保存する
- 記録は best effort: barge-in でキャンセルしたターンの usage は取れないことがあり、推定額は実請求より下振れし得る

## コスト管理上の注意（今後の実装に効く順）

1. TTS は 2026-08-01 の Qwen 切替で約 1/3（$0.05/セッション）になり、**最大要因は会話 LLM の履歴再送**に移った。instruct 変種の正式単価がコンソール / 請求で確認できたら `AIPricing` とこの表を確定する
2. 長セッションでは履歴再送の入力トークンが 2 乗で効く。会話が長くなってコストが気になったら、
   直近ターン末尾への `cache_control` 追加（履歴分も 0.1 倍で読める）が次の最適化候補
3. barge-in で破棄した TTS・キャンセルした Claude 生成分も課金される（仕様上許容。頻発するならセンテンス先読み数の制限を検討）
4. 単価が改定されたら `Usage/AIPricing.swift` とこの文書の単価表を併せて更新する（保存済みの推定額は書き換えない）。
   管理画面「料金」タブの種別内訳に出すモデル・単価は `AIPricing.currentRate(for:)` から生成されるため、コード側を更新すれば自動で追従する
