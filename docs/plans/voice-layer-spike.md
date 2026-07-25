# 音声レイヤの技術検証（調査プラン）

## 目的・背景

esl-speaking-coach は「AI と音声でリアルタイムに英会話練習する iOS ネイティブアプリ」だが、**音声レイヤの実装方式が未決定**。

Anthropic の API にリアルタイム音声（speech-to-speech）のエンドポイントは存在しない（2026-07 時点で再確認済み。Anthropic 自身の Claude アプリの音声モードもターン制の STT → LLM → TTS 構成で、TTS は ElevenLabs 等の外部を利用している）。「リアルタイム双方向音声」は複数の方式で組む必要があり、方式ごとにレイテンシ・コスト・実装量・会話相手のモデルが変わり、机上では決められないので実測して決める。

## 比較する候補（モデルと会話での使い方の定義）

### 案 A: iOS 内蔵音声 + Claude ストリーミング（ターン制パイプライン）

| 役割 | モデル / API | 使い方 |
| --- | --- | --- |
| STT | `SpeechAnalyzer` + `SpeechTranscriber`（iOS 26 / Speech framework） | `SFSpeechRecognizer` の後継。オンデバイス・AsyncSequence ベース。volatile results で逐次認識し、finalized で確定 |
| 発話終端・割り込み検知 | `SpeechDetector`（VAD）+ 無音タイマー | 終端判定と barge-in 検知を自前実装 |
| 会話 LLM | `claude-opus-5` | ストリーミング必須・`effort: low`・`max_tokens` 1024・システムプロンプトは cache_control 付き固定文（CLAUDE.md の規約どおり） |
| TTS | `AVSpeechSynthesizer` | Claude の SSE を文境界で区切り、確定した文から順に読み上げ |
| 評価 LLM | `claude-opus-5` | セッション後に transcript を渡す。`effort: high`・`max_tokens` 16000+ |

会話 1 ターンの流れ:

1. マイク入力 → `SpeechTranscriber` が逐次テキスト化
2. `SpeechDetector` + 無音時間で発話終端を判定 → 確定テキストを user ターンとして自前の履歴モデル（`role` + テキスト）に追加
3. Claude へストリーミングリクエスト（raw HTTP + SSE）
4. 受信テキストを文境界（`.` `?` `!` など）で区切り、確定した文から `AVSpeechSynthesizer` へ流す
5. AI 発話の再生中にユーザーの発話を検知したら、合成を停止して SSE を中断（barge-in 自前実装）

- コスト目安（10 分・20 ターン + 評価 1 回）: テキストトークンのみで **~$0.2〜0.4 / セッション**
- 最大の計測ポイント: `claude-opus-5` は thinking が常時オン（規約により無効化しない）のため、`effort: low` で「発話終了 → 最初の文が確定して読み上げ開始」がどこまで縮むか
- 品質リスク: `AVSpeechSynthesizer` の合成音声の自然さ
- 派生 **案 A'**: A の TTS だけを差し替える。無料の中間段として Kokoro オンデバイス、外部 API なら gpt-4o-mini-tts / Cartesia を第一候補とする（付録参照）。外部 API 構成は Anthropic 公式の音声モードと同構成。A の TTS 品質が不許容だった場合のみ検証する

### 案 B: OpenAI Realtime API（speech-to-speech）

- モデル: `gpt-realtime-2.1`（audio 入力 $32 / 出力 $64 per 1M tokens）。コストが厳しければ `gpt-realtime-2.1-mini`（$10 / $20）
- 接続: iOS からは WebRTC 推奨（WebSocket も可）。マイク入出力ごと API に接続する真の双方向音声
- VAD・発話終端・barge-in はサーバ側ネイティブ。transcript を同時取得して自前の履歴モデルに保存する
- コスト目安（10 分）: 2.1 で **~$2〜5**、mini で **~$0.6〜1.5**（プロンプトキャッシュの効き方に強く依存）
- 会話相手は GPT になる（Claude ではない）
- 同方式の商用代替として **Amazon Nova 2 Sonic**（~$0.015/分、Bedrock・東京リージョンあり）。B のコストが厳しい場合の乗り換え先（付録参照）

### 案 C: Gemini Live API（speech-to-speech）

- モデル: Gemini Flash Live 系（Live API / WebSocket。2026-07 時点の現行は Gemini 3.1 Flash Live。料金は 2.5 Flash Native Audio 時点の値: audio 入力 $3 / 出力 $12 per 1M tokens）
- barge-in・affective dialog（話し方を汲んだ応答）がネイティブ対応。2026 前半に GA 済み
- コスト目安（10 分）: **~$0.1〜0.2** で候補中最安
- Swift 公式 SDK はないため WebSocket を自前実装。会話相手は Gemini になる

### 案 D: ハイブリッド（会話 = B or C、評価 = Claude）

- 会話: 案 B または C の speech-to-speech（発話量を稼ぐためのリアルタイム性を最優先）
- 評価: セッション後に transcript を `claude-opus-5`（`effort: high`）へ渡してフィードバック生成
- API キーが 2 系統になり、Keychain 管理と接続レイヤが複雑化する

## 評価軸

1. **応答レイテンシ**: ユーザーの発話終了 → AI の音声が鳴り始めるまでの実測値（ms）。案 A は「Claude の TTFT + 最初の文の確定」まで分解して記録する
2. **割り込み（barge-in）**: AI の発話中に話しかけたときに自然に止まるか
3. **英語認識精度**: 日本語アクセントの英語をどれだけ正しく取れるか
4. **1 セッション（10 分想定）あたりのコスト**（上記目安を実測で更新する）
5. **実装量**: 動くところまでのコード量・依存の重さ
6. **会話の質**: 英会話コーチとして相手が務まるか（話題の広げ方、聞き返し方）
7. **発音フィードバックの可能性**: 会話中に発音・イントネーションへ言及できるか。単一モデル方式はモデルが音声を直接聞くため構造的に有利で、ターン制はテキスト化の時点でこの情報が消える（付録参照）

## 進め方

### Phase 0: 構成要素の机上調査（完了・2026-07）

TTS / STT / 単一モデル speech-to-speech の候補を案 A〜D の枠にとらわれず調査し、付録に記録した。Phase 1 以降のフォールバック順・代替候補はこの調査に基づく。

### Phase 1: 案 A のプロトタイプ

最小構成で「話す → 返ってくる」を成立させ、評価軸 1〜6 を実測する。Claude は raw HTTP + SSE（Swift の公式 SDK なし）。STT は `SpeechAnalyzer`/`SpeechTranscriber` を第一候補とし、実装上の問題があれば `SFSpeechRecognizer`、日本語アクセント英語での精度不足なら WhisperKit（オンデバイス）→ AssemblyAI / Deepgram（クラウド）の順に切り替えて再計測する（付録参照）。

### Phase 2: 案 B のプロトタイプ

同じ評価軸で OpenAI Realtime API（`gpt-realtime-2.1-mini` から）を実測し、案 A と数値で比較する。コストが厳しいと出た場合は Amazon Nova 2 Sonic を同じ評価軸で代替検証する。

### Phase 3: 判断と方針確定

計測結果を並べて方式を決め、`CLAUDE.md` の「音声レイヤの方針」を確定版に更新する。案 C は Phase 1/2 で結論が出なかった場合のみ追加調査する。案 A' は案 A の TTS 品質が不許容だった場合のみ検証する。

## 影響範囲

- 音声入出力の抽象境界（`VoiceSession` 相当のプロトコル）の形が決まる
- 決定結果に応じて `CLAUDE.md` の技術スタック・方針セクションを更新する
- Phase 2 以降に進む場合、API キーが 2 つになるため Keychain の扱いを見直す

## 検証方法

- ビルドとプロトタイプの動作確認はローカル（Xcode 26.5 + iPhone 17 シミュレータ）で行う
- レイテンシは実機で複数回計測し、中央値を記録する（シミュレータの値は参考値扱い）
- 計測結果はこのプランファイルに追記していき、Phase 3 の判断根拠として残す

## 未決事項

- 案 B / C を試すにあたって各サービスのアカウント・API キーを用意するか（用意しない場合は案 A に確定させる）
- 案 A'（外部 TTS）を検証する場合、どの TTS サービスを使うか（付録の調査より第一候補は gpt-4o-mini-tts / Cartesia。ElevenLabs Flash は品質重視の対抗）
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
