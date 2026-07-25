# 音声レイヤの技術検証（調査プラン）

## 目的・背景

esl-speaking-coach は「AI と音声でリアルタイムに英会話練習する iOS ネイティブアプリ」だが、**音声レイヤの実装方式が未決定**。

Anthropic の API にリアルタイム音声（speech-to-speech）のエンドポイントは存在しない（2026-07 時点で再確認済み。Anthropic 自身の Claude アプリの音声モードもターン制の STT → LLM → TTS 構成で、TTS は ElevenLabs 等の外部を利用している）。「リアルタイム双方向音声」は複数の方式で組む必要があり、方式ごとにレイテンシ・コスト・実装量・会話相手のモデルが変わり、机上では決められないので実測して決める。

**2026-07-24 決定**: iPhone 純正の音声系（`SpeechTranscriber` / `AVSpeechSynthesizer`）は STT・TTS とも不採用（理由は旧案 A 参照）。検証には **OpenAI と Gemini を使う**ことを決定し、比較対象は **案 A2（クラウド STT/TTS + Claude）・案 B（OpenAI Realtime）・案 C（Gemini Live）の 3 本柱**とし、すべてプロトタイプして実測比較する。

## 比較する候補（モデルと会話での使い方の定義）

### 旧案 A: iOS 内蔵音声 + Claude ストリーミング（**廃止**・2026-07-24）

STT を `SpeechTranscriber`（iOS 26）、TTS を `AVSpeechSynthesizer` で組むターン制パイプライン。プロトタイプ実装まで完了したが（下記「旧 Phase 1 実装記録」）、以下の理由で **iPhone 純正の音声系は STT / TTS とも不採用**と判断した。

- STT が初回に数百 MB 規模のモデルダウンロードを要求する
- シミュレータで検証できない（モデル資産が取得できず、音声入力ユニットの初期化が abort する）
- `AVSpeechSynthesizer` の合成音声の品質が会話相手として弱い

Claude クライアント・状態機械・UI などプロバイダ非依存の実装資産は案 A2 に流用する。

### 案 A2: クラウド STT / TTS + Claude ストリーミング（ターン制パイプライン）

会話相手を Claude に保ったまま、音声入出力だけ外部 API に置き換える。**追加キーが OpenAI 1 本で済む構成から始める**（Anthropic 公式の Claude アプリ音声モードと同型の構成。Phase 2 の案 B とキーを共用できる）。

| 役割 | 第一候補 | 差し替え候補（付録参照） |
| --- | --- | --- |
| STT | OpenAI `gpt-4o-transcribe`（Realtime API の transcription セッション / WebSocket ストリーミング） | Deepgram Flux（end-of-turn 検知ネイティブ）→ AssemblyAI Universal |
| 発話終端・割り込み検知 | 無音タイマー + RMS（旧 Phase 1 実装を流用） | Deepgram Flux 採用時はサーバ側検知に置換 |
| 会話 LLM | `claude-opus-5`（規約どおり: ストリーミング・`effort: low`・`max_tokens` 1024・cache_control 付き固定プロンプト） | — |
| TTS | OpenAI `gpt-4o-mini-tts`（HTTP ストリーミング。"speak slowly like an ESL teacher" 等の話し方指示可） | Cartesia Sonic（TTFA 40ms）/ ElevenLabs Flash |
| 評価 LLM | `claude-opus-5`（`effort: high`・`max_tokens` 16000+） | — |

会話 1 ターンの流れは旧案 A と同じ（STT/TTS の実装だけ差し替え）。Claude の SSE を文境界で区切り、確定した文から TTS へ流す。

- コスト目安（10 分・20 ターン + 評価 1 回）: STT ~$0.06 + TTS ~$0.075 + Claude ~$0.2〜0.4 ≒ **~$0.35〜0.55 / セッション**
- 計測ポイント: 旧案 A と同じ分解（無音判定 → STT 確定 → TTFT → 初文 → 発声開始）に加え、STT / TTS のネットワーク往復レイテンシがどれだけ乗るか
- 品質ポイント: 日本語アクセント英語での `gpt-4o-transcribe` の精度（長尺での精度崩壊報告にも注意）。不満なら Deepgram / AssemblyAI へ

### 案 B: OpenAI Realtime API（speech-to-speech）

- モデル: `gpt-realtime-2.1`（audio 入力 $32 / 出力 $64 per 1M tokens）。コストが厳しければ `gpt-realtime-2.1-mini`（$10 / $20）。**案 A2 と同じ OpenAI キーで検証できる**
- 接続: iOS からは WebRTC 推奨（WebSocket も可）。マイク入出力ごと API に接続する真の双方向音声
- VAD・発話終端・barge-in はサーバ側ネイティブ。transcript を同時取得して自前の履歴モデルに保存する
- コスト目安（10 分）: 2.1 で **~$2〜5**、mini で **~$0.6〜1.5**（プロンプトキャッシュの効き方に強く依存）
- 会話相手は GPT になる（Claude ではない）
- 同方式の商用代替として **Amazon Nova 2 Sonic**（~$0.015/分、Bedrock・東京リージョンあり）があるが、低コスト側の比較対象は案 C（Gemini Live）を実測するため、Nova は付録の参考情報にとどめる

### 案 C: Gemini Live API（speech-to-speech）

- モデル: Gemini Flash Live 系（Live API / WebSocket。2026-07 時点の現行は Gemini 3.1 Flash Live。料金は 2.5 Flash Native Audio 時点の値: audio 入力 $3 / 出力 $12 per 1M tokens）
- barge-in・affective dialog（話し方を汲んだ応答）がネイティブ対応。2026 前半に GA 済み
- コスト目安（10 分）: **~$0.1〜0.2** で候補中最安
- Swift 公式 SDK はないため WebSocket を自前実装。会話相手は Gemini になる
- Gemini API キーが必要（Anthropic / OpenAI に続く 3 本目。Keychain `gemini-api-key` + `.secrets/gemini-api-key` シードで同じ仕組みに載せる）

### 案 D: ハイブリッド（会話 = B or C、評価 = Claude）

- 会話: 案 B または C の speech-to-speech（発話量を稼ぐためのリアルタイム性を最優先）
- 評価: セッション後に transcript を `claude-opus-5`（`effort: high`）へ渡してフィードバック生成
- API キーが 2 系統になり、Keychain 管理と接続レイヤが複雑化する

## 評価軸

1. **応答レイテンシ**: ユーザーの発話終了 → AI の音声が鳴り始めるまでの実測値（ms）。案 A2 は「STT 確定 → Claude TTFT → 初文確定 → TTS 発声開始」まで分解して記録する
2. **割り込み（barge-in）**: AI の発話中に話しかけたときに自然に止まるか
3. **英語認識精度**: 日本語アクセントの英語をどれだけ正しく取れるか
4. **1 セッション（10 分想定）あたりのコスト**（上記目安を実測で更新する）
5. **実装量**: 動くところまでのコード量・依存の重さ
6. **会話の質**: 英会話コーチとして相手が務まるか（話題の広げ方、聞き返し方）
7. **発音フィードバックの可能性**: 会話中に発音・イントネーションへ言及できるか。単一モデル方式はモデルが音声を直接聞くため構造的に有利で、ターン制はテキスト化の時点でこの情報が消える（付録参照）

## 進め方

### Phase 0: 構成要素の机上調査（完了・2026-07）

TTS / STT / 単一モデル speech-to-speech の候補を案 A〜D の枠にとらわれず調査し、付録に記録した。Phase 1 以降のフォールバック順・代替候補はこの調査に基づく。

### 旧 Phase 1: 旧案 A のプロトタイプ（**中止**・記録として保持）

旧案 A の廃止に伴い、実機実測の前に中止（2026-07-24）。実装資産のうちプロバイダ非依存の部分は Phase 1（案 A2）で流用する:

- 流用する: `VoiceSession` プロトコル境界 / `TurnBasedVoiceSession` の状態機械（無音判定・barge-in・計測）/ `ClaudeMessagesClient`（SSE、実キーで E2E 検証済み）/ `SentenceChunker` / `CoachSystemPrompt` / 会話 UI・計測表示 / デバッグ起動引数
- 置換・削除する: `UtteranceTranscriber`（SpeechAnalyzer 依存）/ `SentenceSpeaker` の AVSpeechSynthesizer 実装 → 案 A2 実装時にクラウド STT / TTS 実装へ差し替える

#### 旧 Phase 1 実装記録（2026-07-24: プロトタイプ実装完了、実機実測前に中止）

**実装構成**（deployment target を iOS 26.0 に引き上げ）:

| ファイル | 役割 |
| --- | --- |
| `Voice/VoiceSession.swift` | 抽象境界。`VoiceSession` プロトコル + `VoiceSessionEvent` + `TurnMetrics`。UI はこれにのみ依存 |
| `Voice/TurnBasedVoiceSession.swift` | 案 A の状態機械（listening → thinking → speaking → listening）。無音判定・barge-in・レイテンシ計測。インスタンスは使い捨て |
| `Voice/UtteranceTranscriber.swift` | `SpeechAnalyzer` + `SpeechTranscriber` の 1 発話ラッパ。モデル準備は reserve → assetInstallationRequest |
| `Voice/MicrophoneCapture.swift` | `AVAudioEngine` タップ + RMS レベル + `AVAudioConverter` で analyzer フォーマットへ変換 |
| `Voice/SentenceSpeaker.swift` | `AVSpeechSynthesizer` のターン単位キュー。en-US の premium > enhanced > default を自動選択 |
| `Voice/SentenceChunker.swift` | SSE デルタの文境界分割（"3.5" 非分割・閉じ引用符対応。ユニットテストあり） |
| `Claude/ClaudeMessagesClient.swift` | raw HTTP + SSE。規約どおり（temperature 等なし・effort low・max_tokens 1024・cache_control）。リクエスト形式はユニットテストで固定 |
| `Claude/CoachSystemPrompt.swift` | 固定システムプロンプト（512 トークン超、キャッシュ前提） |
| `Conversation/*` | 会話画面。状態・ライブ文字起こし・RMS 表示・ターンごとの計測値表示 |

**タイムスタンプ分解**（評価軸 1）: 発話終端 → 無音判定(silenceWindow=1.0s 固定) → STT 確定 → リクエスト → TTFT → 初文確定 → 発声開始。各区間 ms を画面に表示（`TurnMetrics`）。

**シミュレータの制限（実測できず。実機必須の根拠）**:

- `SpeechTranscriber` のモデル資産が取得できない（`AssetInventory` が `status=unsupported`、`assetInstallationRequest` は "not subscribed to transcription.en" で失敗）
- 音声入力ユニットの初期化が CoreAudio の RPC タイムアウトで **abort する**（`AVAudioEngine.inputNode` にアクセスした時点でクラッシュ。アプリ側で捕捉不能）
- 対応: シミュレータではマイク・STT に触らず、DEBUG 限定のテキスト入力でターンを回す検証モードに劣化させた。Claude SSE・文分割・TTS・状態遷移・エラー復帰はシミュレータで検証済み（ダミーキーで 401 → エラー表示 → listening 復帰まで確認）

**デバッグ用起動引数**（シミュレータ検証用）:

```bash
xcrun simctl launch booted com.akiraak.EslSpeakingCoach \
  -start-conversation -send-text "Hello coach"
# ほか: -seed-anthropic-key <key> / -delete-anthropic-key / -open-conversation
```

**シミュレータで確認済みの参考値**（実キー・テキスト入力経由の 1 ターン）: Claude TTFT 1905ms（`effort: low`）、初文は最初のデルタに含まれ 0ms、TTS 発声開始 +42ms。TTFT ≈ 2 秒が Claude 側の基礎レイテンシとして乗る前提で案 A2 / 案 B を比較する。

### Phase 1: 案 A2（クラウド STT / TTS + Claude）のプロトタイプと実測

1. **準備**: OpenAI API キーを取得。`KeychainStore` に `openai-api-key` アカウントを追加し、`.secrets/openai-api-key` からのシードに対応（Anthropic キーと同じ仕組み）
2. **STT**: `gpt-4o-transcribe` の WebSocket ストリーミングを `UtteranceTranscriber` の後継として実装（`VoiceSession` 境界は変えない）。マイクは既存の `MicrophoneCapture` を流用し、16kHz PCM16 へ変換して送る
3. **TTS**: `gpt-4o-mini-tts` のストリーミング再生を `SentenceSpeaker` の後継として実装。文単位で生成リクエストし、到着順に再生キューへ
4. **実測**: 実機で評価軸 1〜6 を計測（分解は旧 Phase 1 と同じ + STT / TTS のネットワーク往復）。10 ターン以上の中央値を下表に記録
5. **差し替え判断**: STT の精度・終端検知に不満があれば Deepgram Flux（end-of-turn 検知で無音タイマー自体を置換できる）、TTS 品質に不満があれば Cartesia へ

**実測記録（実機・中央値）**: ※未計測

| 項目 | 値 (ms) | メモ |
| --- | --- | --- |
| 体感（発話終端 → 発声開始） | - | |
| 無音待ち（silenceWindow） | - | 既定 1000ms 固定 |
| STT 確定 | - | ネットワーク往復含む |
| TTFT（Claude） | - | シミュレータ参考値 ~1900ms |
| 初文確定 | - | |
| 発声開始（TTS 往復含む） | - | |

### Phase 2: 案 B（OpenAI Realtime speech-to-speech）のプロトタイプと実測

同じ評価軸で OpenAI Realtime API（`gpt-realtime-2.1-mini` から。案 A2 と同じキー）を実測し、案 A2 と数値で比較する。

### Phase 3: 案 C（Gemini Live speech-to-speech）のプロトタイプと実測

1. **準備**: Gemini API キーを取得。`KeychainStore` に `gemini-api-key` アカウントを追加し、`.secrets/gemini-api-key` からのシードに対応（既存 2 キーと同じ仕組み）
2. **実装**: Live API（WebSocket）を自前実装し、`VoiceSession` の実装として追加する（公式 Swift SDK なし。マイクは `MicrophoneCapture` を流用）。VAD・発話終端・barge-in はサーバ側を使う
3. **実測**: 同じ評価軸で実機計測。speech-to-speech 同士となる案 B との直接比較（レイテンシ・会話の質・コスト）と、評価フェーズで Claude に渡す transcript の品質を重点的に見る

### Phase 4: 判断と方針確定

案 A2 / 案 B / 案 C の計測結果を並べて方式を決め、`CLAUDE.md` の「音声レイヤの方針」を確定版に更新する。判断の前に「会話中の発音指摘を製品価値とするか」を決める（評価軸 7。案 B / C の単一モデル方式が構造的に有利）。

## 影響範囲

- 音声入出力の抽象境界（`VoiceSession` 相当のプロトコル）の形が決まる
- 決定結果に応じて `CLAUDE.md` の技術スタック・方針セクションを更新する
- Phase 1 の時点で OpenAI キーが加わり 2 キー管理、Phase 3 で Gemini キーが加わり 3 キー管理になる。`KeychainStore` はアカウント別保存に対応済みなので、`openai-api-key` / `gemini-api-key` アカウントの追加と `.secrets/openai-api-key` / `.secrets/gemini-api-key` からのシード（起動引数の拡張）を行う
- Apple 依存の実装（`UtteranceTranscriber`・`SentenceSpeaker` の AVSpeech 部分）は案 A2 実装時に削除する

## 検証方法

- ビルドとプロトタイプの動作確認はローカル（Xcode 26.5 + iPhone 17 シミュレータ）で行う
- レイテンシは実機で複数回計測し、中央値を記録する（シミュレータの値は参考値扱い）
- 計測結果はこのプランファイルに追記していき、Phase 3 の判断根拠として残す

## 未決事項

- ~~案 B / C のアカウント・API キーを用意するか~~ → **OpenAI キー・Gemini キーとも用意する（2026-07-24 確定。OpenAI は案 A2 / 案 B で共用、Gemini は案 C 用）**
- **会話中の軽い発音指摘を製品価値とするか**。するなら単一モデル方式（案 B / C 系）が構造的に有利なため、評価軸 7 の重み付けとして方式決定（Phase 3）の前に決める

## 付録: TTS / STT 単体の候補調査（2026-07 時点）

案 A のパイプラインは STT / TTS を個別に差し替えられるため、案 A〜D の枠にとらわれず構成要素単体の候補を調査した。コスト目安は「10 分セッション、AI 発話 約 5 分 ≒ 4,000 文字、ユーザー発話含むマイク常時オン 10 分」で換算。

### TTS（音声生成）の候補

**① 端末内・無料（ネットワークレイテンシゼロ）**

| 候補 | 特徴 | 懸念 |
| --- | --- | --- |
| `AVSpeechSynthesizer`（現行案） | 追加実装ほぼゼロ。Premium/Enhanced 音声で改善可。rate 調整が容易で「ゆっくり話して」に即対応 | 合成音声感。会話相手としての魅力 |
| Kokoro-82M オンデバイス（CoreML / MLX Swift / sherpa-onnx） | オープンウェイトのニューラル TTS。iPhone 16 Pro で RTF 0.08、iPhone 13 Pro でも 3.3 倍速の報告。無料・オフライン・API キー不要で AVSpeech より自然 | 若いライブラリ（kokoro-swift-mlx / kokoro-coreml / speech-swift）への依存。感情表現は限定的 |

**② クラウド・低レイテンシ特化（voice agent 向け、全て WebSocket ストリーミングあり）**

| 候補 | TTFA | 料金 | セッション単価目安 |
| --- | --- | --- | --- |
| Cartesia Sonic 4 / Turbo | 約 40ms（商用最速） | ~$30/1M 文字 | ~$0.12 |
| ElevenLabs Flash v2.5 | 約 75ms | $50〜60/1M 文字 | ~$0.2〜0.25 |
| Deepgram Aura-2 | 90〜200ms | $30/1M 文字 | ~$0.12 |
| Rime | sub-100ms | 同水準 | ~$0.1〜0.2 |

品質の評判は ElevenLabs > Cartesia ≧ Rime > Aura-2 の論調。Cartesia / ElevenLabs は単語タイムスタンプを返せる（将来の字幕ハイライトに有用）。

**③ クラウド・大手汎用**

| 候補 | 特徴 | セッション単価目安 |
| --- | --- | --- |
| OpenAI gpt-4o-mini-tts | $0.015/分と最安級。プロンプトで話し方を指示可能（"speak slowly like an ESL teacher" が効く）。HTTP ストリーミングのみ（WebSocket なし、ターン制なら問題なし） | ~$0.075 |
| Gemini TTS（2.5 Flash TTS） | 同じく指示可能型。音声トークン課金でやや高め | ~$0.1 |
| Azure AI Speech / Google Chirp3 / Amazon Polly | $15〜30/1M 文字。SSML で話速・ポーズ制御が細かい。品質は②にやや劣るが枯れて安定 | $0.06〜0.12 |

**④ 表現力特化**: Hume Octave（感情指示に強い、高め）、ElevenLabs v3 系（最高品質だが $100+/1M 文字・非リアルタイム向け。セッション後フィードバックの読み上げ用途なら候補）。

**含意**: 案 A（AVSpeech）と案 A'（外部 TTS）の間に「Kokoro オンデバイス」という無料の中間案が挟める。案 A' の第一候補は価格・ESL 適性（話し方指示）で gpt-4o-mini-tts か Cartesia。

### STT（音声認識）の候補

**① 端末内・無料**

| 候補 | 特徴 | 懸念 |
| --- | --- | --- |
| `SpeechAnalyzer`/`SpeechTranscriber`（iOS 26、現行案） | 独立ベンチマーク（Inscribe、2026-07）で LibriSpeech WER 2.12%（クリア）/ 4.56%（ノイズ）と Whisper Small（3.74% / 7.95%）を上回り、処理速度は約 3 倍。旧 `SFSpeechRecognizer` 比で誤り約 75% 減。ストリーミング・AsyncSequence ネイティブ | ベンチはネイティブ話者の読み上げ英語のみ。**日本語アクセント英語での精度は未知数 → Phase 1 の実測ポイント** |
| WhisperKit（Argmax） | Whisper を CoreML/ANE で実行。MIT ライセンス。アクセント付き・ノイズ音声に強く、iPhone 15 Pro で sub-100ms のストリーミング報告 | モデルダウンロードとバッテリー消費。SpeechTranscriber がアクセントで失速した場合の第一フォールバック |
| FluidAudio + Parakeet TDT 0.6B（CoreML） | Open ASR Leaderboard の WER 上位。実時間よりはるかに高速。20+ の製品アプリで実績 | v2 は英語のみ（本用途では問題なし）。ライブラリは若い |

**② クラウド・ストリーミング**

| 候補 | 精度・レイテンシ | 料金（ストリーミング） | セッション単価目安 |
| --- | --- | --- | --- |
| Deepgram Nova-3 / Flux | 英語バッチ WER 5.26% で首位級。sub-300ms。**Flux はターン検知（end-of-turn）ネイティブ対応** → 発話終端・barge-in の自前実装を丸ごと置き換えられる可能性 | $0.0077/分 | ~$0.08 |
| AssemblyAI Universal-3.5 Pro Realtime | Pipecat ベンチで pooled WER 6.99%（首位）。P50 ~150ms。非ネイティブ英語の研究でも Whisper と並び最良（MER 0.056） | ~$0.21〜0.37/時 | ~$0.04〜0.06 |
| ElevenLabs Scribe v2 Realtime | <150ms、多言語に強い | — | — |
| OpenAI gpt-4o-transcribe | Realtime API 経由でストリーミング可。ただし長尺で精度崩壊の報告あり | $0.006/分 | ~$0.06 |
| Speechmatics Ursa 2 | 55+ 言語、アクセント頑健性を訴求 | — | — |

**③ 日本語アクセント英語という固有の論点**

- 商用 ASR はアジア系アクセントでネイティブ比 3〜5 倍の誤り率という研究報告がある。一方、非ネイティブ読み上げ英語では Whisper / AssemblyAI が人間に迫る精度という報告もあり、**モデル差が大きい。自分の声での実測が必須**
- コーチ用途では「言い間違いを補正しすぎる STT」は発音フィードバックの材料を消してしまう。会話用（補正強め）と評価用（生の認識結果）で要求が異なる可能性に留意

**含意**: Phase 1 は現行案どおり `SpeechTranscriber` で開始し、日本語アクセント英語での実測 WER が悪ければ WhisperKit（オンデバイス）→ AssemblyAI / Deepgram（クラウド）の順に検証する。Deepgram Flux のターン検知は、案 A の弱点（発話終端・barge-in 自前実装）を外部化できる点で単なる STT 差し替え以上の意味がある。

### 単一モデル speech-to-speech の候補（TTS / STT を分けない方式）

案 B / C がこの方式に当たるが、2026-07 時点で商用の選択肢が増えている。方式共通の性質:

- **長所**: STT → LLM → TTS の累積レイテンシがない。トーン・ピッチ・間を「聞いた」うえで応答するので、テキスト化で失われる発音・感情に反応できる（ESL 用途では固有の魅力）。VAD・発話終端・barge-in がネイティブ
- **短所**: 会話相手が Claude ではなくなる。transcript は副産物（評価フェーズで Claude に渡す transcript の品質はモデル依存 → 検証項目）

| 候補 | 特徴 | 10 分あたりコスト目安 |
| --- | --- | --- |
| OpenAI gpt-realtime-2.1（= 案 B） | 最も成熟。WebRTC 推奨 | 2.1 で ~$2〜5、mini で ~$0.6〜1.5 |
| Gemini Live（= 案 C。現行モデルは Gemini 3.1 Flash Live） | マルチモーダル対応が最も広く、多言語に強い。候補中最安 | ~$0.1〜0.2 |
| **Amazon Nova 2 Sonic**（Bedrock） | 音声 $3/1M 入力・$12/1M 出力トークン ≒ **$0.015/分**（GPT-4o Realtime 比 ~80% 安）。ノイズ・話し方への頑健性を訴求。東京リージョンあり | ~$0.15 |
| Hume EVI 3 | 感情検知・共感応答に特化。<300ms・11 言語。課金はサブスク型（従量ではない） | プラン依存 |
| xAI Voice | 同クラスの新顔。詳細未調査 | — |

**オープンウェイト**（Moshi / Qwen2.5-Omni / PersonaPlex 等）: full-duplex 200ms 級の研究成果はあるが、iPhone 上で動く実用例がない（3B〜7B + 音声コーデックで端末実行は非現実的）。自前サーバーでのホストは「バックエンドなし」方針と矛盾するため、現時点では対象外とする。

**含意**:

- 単一モデル方式の商用候補は案 B / C に加えて **Nova 2 Sonic が第三の選択肢**（価格は案 B mini と案 C の中間、Bedrock 経由・東京リージョンあり）。Phase 2 で案 B が高コストと出た場合の乗り換え先になり得る
- Anthropic に speech-to-speech はない（既述）ため、この方式を採る場合は必然的に案 D 構成（評価のみ Claude）になる
- ESL 固有の論点: モデルが発音・イントネーションを直接「聞いて」いるため、「今の発音は t が抜けていた」のような音声レベルのフィードバックが原理的に可能。ターン制パイプライン（案 A）ではテキスト化の時点でこの情報が消える。会話中の軽い発音指摘を製品価値とするなら単一モデル方式が構造的に有利

**出典**: [FutureAGI TTS 2026](https://futureagi.com/blog/best-text-to-speech-providers-2026/) / [Cekura TTS ランキング](https://www.cekura.ai/blogs/best-tts-for-ai-voice-agents) / [Deepgram vs Cartesia](https://onepin.ai/blog/deepgram-aura-2-vs-cartesia-sonic-voice-agents-2026) / [OpenAI TTS 料金](https://texttolab.com/blog/openai-tts-pricing) / [kokoro-swift-mlx](https://github.com/mattmireles/kokoro-swift-mlx) / [speech-swift](https://github.com/soniqo/speech-swift) / [SpeechAnalyzer ベンチマーク（Inscribe）](https://get-inscribe.com/blog/apple-speech-api-benchmark.html) / [WhisperKit vs SpeechAnalyzer](https://vocai.net/blog/whisperkit-vs-speechanalyzer-2026/) / [FluidAudio / Parakeet](https://macparakeet.com/blog/fluidaudio-speech-ai-sdk/) / [Inworld STT 2026](https://inworld.ai/resources/best-speech-to-text-apis) / [Deepgram Nova-3 料金](https://convertaudiototext.com/blog/deepgram-nova-3-explained) / [非ネイティブ英語 ASR 研究 (arXiv:2503.06924)](https://arxiv.org/abs/2503.06924) / [Inworld: Best Speech-to-Speech APIs 2026](https://inworld.ai/resources/best-speech-to-speech-apis) / [Amazon Nova 料金](https://aws.amazon.com/nova/pricing/) / [Nova 2 Sonic 発表](https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-nova-2-sonic-real-time-conversational-ai) / [S2S モデル 2026 レビュー](https://ai.ksopyla.com/posts/voice-to-voice-models-2026-review/) / [Moshi (Kyutai)](https://github.com/kyutai-labs/moshi) / [Hume AI 料金](https://affinco.com/hume-ai-pricing/)
