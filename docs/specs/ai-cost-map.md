# AI 利用料金マップ（どの操作でどの API に課金が発生するか）

2026-07-25 作成。本アプリはバックエンドなしで 3 プロバイダ（Anthropic / OpenAI / Google Gemini）の API をアプリから直叩きするため、課金が発生する箇所をここに集約する。将来の「管理画面（AI 利用料金）」タスクの土台でもある。

- 単価は **2026-07-25 時点**の各社公表値。変動前提で、実装時は必ず最新の料金ページを確認する
  - Anthropic: https://platform.claude.com/docs/en/pricing
  - OpenAI: https://platform.openai.com/pricing
  - Gemini: https://ai.google.dev/gemini-api/docs/pricing
- 「実装状況」は 2026-07-25 時点。未実装のものは仕様（[conversation-design.md](conversation-design.md)）ベースで記載する

## 課金マップ（サマリ）

| # | 操作 | API / モデル | 課金単位 | 発生タイミング | 実装状況 |
| --- | --- | --- | --- | --- | --- |
| 1 | 発話の文字起こし（STT） | OpenAI Realtime transcription / `gpt-4o-transcribe` | **ユーザーが実際に話した音声の長さ**（VAD が切り出した発話セグメントのみ。無音・待機中は課金されない） | 会話セッション中、ユーザーが話すたび | 実装済み |
| 2 | 会話ターン生成（LLM） | Claude Messages / `claude-sonnet-5` | 入力トークン + 出力トークン（**毎ターン履歴全体を再送**） | ユーザー発話が確定するたび 1 回 | 実装済み |
| 3 | 読み上げ（TTS） | Gemini `gemini-3.1-flash-tts-preview` | テキスト入力トークン + **音声出力トークン（25 トークン/秒）** | AI 発話の **1 文ごと**に 1 リクエスト | 実装済み |
| 4 | トピック候補生成 | Claude Messages / `claude-sonnet-5` | 入力 + 出力トークン(少量) | 初回起動時 / セッション終了直後 / 「🔄 他の候補」タップ時 | 実装済み |
| 5 | セッション後フィードバック生成 | Claude Messages / `claude-opus-5` | 入力（会話全文）+ 出力トークン（effort high・max_tokens 16000） | セッション正常終了ごとに 1 回（学習者の発話 2 未満はスキップ。失敗時のリトライも課金） | 実装済み |
| 6 | 記憶ノート更新 | Claude Messages / `claude-sonnet-5` | 入力（前回ノート + 会話全文）+ 出力トークン（max_tokens 2000） | セッション正常終了ごとに 1 回（学習者の発話 2 未満はスキップ。失敗してもリトライ導線なし） | 実装済み |
| 7 | 会話の翻訳 | Claude Messages / `claude-haiku-4-5` | 入力（トピック + 直前 8 発話の文脈 + 対象発話）+ 出力トークン（日本語訳のみ） | **訳の表示が ON のときだけ**。ターン終了ごと + セッション終了時 + OFF → ON にした時 + 訳 ON のまま起動した時 | 実装済み |

## 単価表（2026-07-25 時点）

| API | 単価 | 目安に直すと |
| --- | --- | --- |
| OpenAI `gpt-4o-transcribe`（STT） | 約 $0.006 / 音声 1 分 | ユーザーが 10 分話して約 $0.06 |
| （参考）OpenAI `gpt-live-transcribe`（STT 検証用切替・未採用） | セッション音声 $0.017 / 分（usage は duration 型・秒単位切り上げ） | サーバ VAD 非対応のため見送り（[検証記録](../plans/archive/gpt-live-transcribe-verification.md)） |
| Gemini 3.1 Flash TTS preview | 入力 $1 / 1M トークン、音声出力 $20 / 1M トークン（25 トークン/秒） | **生成音声 1 分 ≈ $0.03**（1,500 トークン） |
| （参考）Gemini 2.5 Flash TTS preview | 入力 $0.50 / 1M、出力 $10 / 1M | 生成音声 1 分 ≈ $0.015（3.1 の半額） |
| （参考）OpenAI `gpt-4o-mini-tts`（切替用） | 音声 1 分 ≈ $0.015（参考値・要再確認） | — |
| Claude `claude-sonnet-5` | 入力 $3 / 出力 $15 / 1M トークン（〜2026-08-31 は導入価格 $2 / $10） | — |
| Claude `claude-opus-5` | 入力 $5 / 出力 $25 / 1M トークン | — |
| Claude プロンプトキャッシュ | 書き込み 1.25 倍（5 分 TTL）、読み込み 0.1 倍 | system prompt（約 2,000 トークン）は 2 ターン目以降ほぼタダ |

## 各操作の詳細

### 1. STT（発話の文字起こし）

- 実装: `Voice/CloudPipeline/OpenAITranscriptionStream.swift` + `OpenAITranscriptionProtocol.swift`
- セッション開始時に WebSocket（`wss://api.openai.com/v1/realtime?intent=transcription`）を張り、マイク音声（PCM16 24kHz）を**セッション中ずっと**流し続ける
- ただし課金対象はサーバ VAD が発話と判定して transcription にかけたセグメントのみ。**無音や AI の発話待ち時間はストリームしていても課金されない**（OpenAI の課金ドキュメントの明記事項。逆に言うと「アプリを開いている時間」ではなく「ユーザーが話した時間」に比例する）
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

- 実装: `Voice/CloudPipeline/GeminiTTSClient.swift` + `CloudSentenceSpeaker.swift`（切替用に `OpenAITTSClient.swift`）
- Claude のストリーミングから文が切り出されるたびに **1 文 = 1 リクエスト**。入力はスタイル前置文 + 文テキスト、出力は 24kHz PCM 音声
- 支配的なのは音声出力側: **$20 / 1M トークン × 25 トークン/秒 = 生成音声 1 分あたり約 $0.03**。AI がよく喋るアプリなので、**1 セッションの中では TTS が最大のコスト要因になりやすい**
- スタイル前置文（現在約 25 トークン、2 キャラ化後はキャラ別）は文ごとに毎回入力に含まれるが、$1 / 1M なので実質無視できる
- **barge-in 時の注意**: 先読みで取得済み・取得中だった未再生の文も生成された分は課金される（`CloudSentenceSpeaker` は再生をキャンセルするだけで、生成済み音声の費用は返らない）
- モデルは調整中。2.5 Flash TTS に落とすと音声出力が半額（$10 / 1M ≈ $0.015/分）

### 4. トピック候補生成（実装済み）

- 実装: `Claude/TopicSuggestionClient.swift`、呼び出し元 `Conversation/ChatRoomStore.swift`
- 仕様: [conversation-design.md](conversation-design.md) の「トピック生成」。`claude-sonnet-5` / 非ストリーミング / effort low / structured outputs
- 呼び出しタイミングは 3 つ: 初回起動時 / セッション終了直後 / 「🔄 他の候補」タップ時
- 入力（固定 system prompt + 直近トピック一覧）も出力（タイトル + フック × 3 件）も数百トークン規模で、**1 回 $0.01 未満**。連打されても実害が出にくいが、🔄 は課金操作である点は管理画面で見えるようにする

### 5. セッション後フィードバック生成（実装済み）

- 仕様: [session-feedback.md](session-feedback.md)。`claude-opus-5` / effort high / max_tokens 16000 / ストリーミング + structured outputs
- 入力に**会話全文**を渡すため、セッションが長いほど入力コストが増える。出力も数千トークン規模になり得る
- **単発の API 呼び出しとしてはアプリ内で最も高額**（opus 単価 × 長文入出力）。ただしセッションごとに 1 回だけ

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
| STT（ユーザー発話 5 分） | 5 × $0.006 | $0.03 |
| TTS（生成音声 5 分、3.1 Flash TTS） | 5 × $0.03 | $0.15 |
| 会話 LLM 入力（履歴、平均 1,500 × 30 ターン） | 45K トークン × $3/1M | $0.14 |
| 会話 LLM 入力（キャッシュ済み system、2,000 × 30） | 60K × $0.3/1M + 初回書込 | $0.03 |
| 会話 LLM 出力（約 100 × 30 ターン） | 3K × $15/1M | $0.05 |
| フィードバック生成（opus、入力 5K / 出力 3K） | $5/1M × 5K + $25/1M × 3K | $0.10 |
| トピック生成 | — | $0.01 未満 |
| **合計** | | **約 $0.5 / セッション** |

- 毎日 1 セッションで **月 $15 前後**が目安
- コストの並びは概ね **TTS ＞ 会話 LLM ≧ フィードバック ＞ STT ＞ トピック生成**

## 利用量の記録（2026-07-25 実装）

管理画面「AI 利用料金」のため、6 経路すべてで API レスポンスの usage を記録している
（実装プラン: `docs/plans/archive/history-persistence-and-admin.md`）。

- 取得元: Claude は SSE の `message_start` / `message_delta`（非ストリーミングは応答の `usage`）、
  OpenAI STT は transcription completed イベントの usage（tokens 型 / duration 型両対応）、
  Gemini TTS は SSE の `usageMetadata`（+ 受信 PCM バイト数からの秒数）
- 記録: `Persistence/UsageStore.swift`（`APIUsageRecord`）。生の usage と、**記録時に** `Usage/AIPricing.swift`
  の単価表（この文書の単価表と対応。sonnet-5 の導入価格切替も考慮）で計算した推定額を保存する
- 記録は best effort: barge-in でキャンセルしたターンの usage は取れないことがあり、推定額は実請求より下振れし得る

## コスト管理上の注意（今後の実装に効く順）

1. **TTS が最大要因**。モデル調整（TODO）で 2.5 Flash TTS と聞き比べる際は「半額」という材料も含めて判断する
2. 長セッションでは履歴再送の入力トークンが 2 乗で効く。会話が長くなってコストが気になったら、
   直近ターン末尾への `cache_control` 追加（履歴分も 0.1 倍で読める）が次の最適化候補
3. barge-in で破棄した TTS・キャンセルした Claude 生成分も課金される（仕様上許容。頻発するならセンテンス先読み数の制限を検討）
4. 単価が改定されたら `Usage/AIPricing.swift` とこの文書の単価表を併せて更新する（保存済みの推定額は書き換えない）
