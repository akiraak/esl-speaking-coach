# 安い中国系 AI モデルの調査プラン

2026-07-31 作成。調査タスク（このプラン自体ではコードを変更しない）。

## 目的・背景

- 現在の LLM コストは `claude-sonnet-5`（会話ターン・トピック生成・フィードバック・記憶ノート）+ `claude-haiku-4-5`（翻訳）。[ai-cost-map.md](../specs/ai-cost-map.md) の概算では 1 セッション約 $0.52 のうち LLM が約 $0.28（会話 $0.22 + フィードバック $0.06）を占める
- 中国系モデル（DeepSeek / Qwen / Kimi / GLM / MiniMax など）は sonnet 比で入出力単価が 1/10〜1/30 クラスと言われており、品質が許容範囲なら LLM コストを大きく下げられる可能性がある
- ただし CLAUDE.md の音声レイヤ決定は「**会話相手を Claude に保てること**」が決め手だった経緯がある。会話ターンの置き換えは品質次第で慎重に判断する（周辺経路 = フィードバック・トピック・記憶ノート・翻訳だけの置き換えでは節約幅が小さい点も含めて評価する）
- 個人ツールとはいえ会話全文を送る先が変わるため、各社のデータ保持・学習利用ポリシーも判断材料に含める

## 対応方針

### Phase 1: 机上調査（モデル・料金・API 仕様の一覧化）

候補プロバイダごとに以下を表にまとめ、このプランに追記する。**単価は必ず各社の最新料金ページで確認する**（知識ベースの数字を書かない）。

- 候補（2026-07 時点の当たり）: DeepSeek（deepseek-chat / V3 系）、Alibaba Qwen（Model Studio 国際エンドポイント）、Moonshot Kimi（K2 系）、Zhipu GLM（z.ai 国際版）、MiniMax。必要なら OpenRouter 経由の利用（キー 1 本で複数モデル比較できる）も併記する
- 調査項目:
  - 単価（入力 / 出力 / キャッシュヒット、$ / 1M トークン）と、sonnet-5（$3 / $15）比
  - API 形式: OpenAI 互換か、SSE ストリーミング、structured outputs / JSON mode の有無（トピック・フィードバック・翻訳で必須）、system prompt キャッシュの仕組み（毎ターン履歴再送のコスト構造に直結）
  - 国際エンドポイントの有無と拠点（日本からのレイテンシ見込み）、決済手段
  - データ保持・学習利用ポリシー（会話全文を送って良いか）
  - 英語会話品質の評判（英語ネイティブらしさ、ESL 相手の応答品質）
- あわせて中国系の音声モデル（TTS: MiniMax speech 系 / Qwen-TTS、STT: SenseVoice 系など）の単価だけ簡易に調べる。TTS が最大コスト要因（$0.03/分）のため、LLM より効く可能性があれば別タスクとして起こす

### Phase 2: API キー収集（アカウント作成・キー配置）

Phase 1 の絞り込み結果に基づき、実測に使うプロバイダのアカウントと API キーを用意する（アカウント作成・決済はユーザー作業）。

- **Alibaba Cloud（Model Studio 国際版）**: アカウント作成 → Model Studio 有効化 → API キー発行。本命 Qwen の東京リージョン直叩き検証用。無料枠（モデルごと 100 万トークン / 90 日）があるため Phase 3 は無料枠内で完結見込み
- **OpenRouter**: アカウント作成 → クレジット購入（$5〜10。カード手数料 5.5%・最低 $0.80）→ API キー発行。GLM / DeepSeek / MiniMax をキー 1 本で品質比較する用
- （任意）Z.ai 直のキーは GLM が最終候補に残った場合のみ検討。決済が 3DS 非対応のため、OpenRouter 経由で代替できる間は作らない
- キーの置き場所: 既存規約（`.secrets/<provider>-api-key`、git 管理外・1 行プレーンテキスト）に合わせて **`.secrets/dashscope-api-key`** / **`.secrets/openrouter-api-key`** に置く
- 配置後、scratchpad から curl で 1 リクエストの疎通確認（課金最小のモデル・数トークン）が通ったら Phase 2 完了
- この時点ではアプリ本体には組み込まない（Keychain seed への追加は採用決定後の実装タスクで行う）

### Phase 3: 実測比較（品質・レイテンシ）

Phase 1 で残った 2〜3 モデルに絞り、API を実際に叩いて比較する。コードはアプリに入れず、scratchpad のスクリプト（curl / node）で行う。

- レイテンシ: 会話ターン相当のリクエスト（2 キャラ台本 system prompt 約 2,000 トークン + 履歴）で **TTFT（最初のトークンまで）と 1 文確定までの時間**を日本から実測し、sonnet-5 と並べる。ターン制パイプラインでは TTFT がそのまま応答の間になるため最重要
- 会話品質: 実セッションの履歴（数ターン分）を流用し、(1) 英語のみを維持するか（日本語に切り替えないか）、(2) 台本形式（2 キャラ）の出力形式指示に従うか、(3) ESL 学習者相手として自然か、を sonnet-5 の応答と並べて評価する
- フィードバック品質: 実セッション 1 件の会話全文で [session-feedback.md](../specs/session-feedback.md) 相当のプロンプトを実行し、structured outputs の安定性と指摘の質を比較する
- 判定は **`claude-opus-5` を判定者（LLM-as-judge）にする**
  - 機械的に確認できる項目（英語のみ維持・中国語 / ピンイン混入・台本 / JSON の形式遵守）はスクリプトで検査する
  - 主観品質（ESL 学習者相手としての自然さ・フィードバックの指摘の質）は、候補モデルと sonnet-5 の出力を**モデル名を伏せて**ペアで opus-5 に渡し、観点ごとに採点 + 理由付きで比較させる。位置バイアス対策で提示順を入れ替えて 2 回評価し、結果が割れたら引き分け扱いにする
  - 判定リクエストは通常の Messages API（`claude-opus-5`、`effort: high`、structured outputs で採点 JSON を受ける）。scratchpad のスクリプトから叩き、アプリには入れない
  - 最終的な採用判断は opus-5 の判定結果を材料に自分が下す（目視のサイドバイサイド確認も併用する）

### Phase 4: 判断とまとめ

- [ai-cost-map.md](../specs/ai-cost-map.md) の概算例（15 分 / 30 ターン）を候補モデルの単価で再計算し、**1 セッション・月額でいくら下がるか**を出す
- 経路ごと（会話 / フィードバック / トピック / 記憶ノート / 翻訳）に「置き換える / 置き換えない / 保留」を決め、結論と根拠をこのプランに記録する
- 採用する場合は**実装タスクを別途 `TODO.md` に起こす**（このタスクは調査で完結）

### Phase 5: 生成品質の厳密チェック（Phase 4 の後に実施）

- Phase 3 の品質評価はケース 4 件 × 各 1 生成・判定 1 ペアずつのスモークテスト規模だった。Phase 4 の採否判断で残った候補に対し、より厳密な評価を行う
- 方向性（詳細は着手時に具体化）: 会話ケース数と生成回数を増やす（同一ケース複数生成でばらつきも見る）、フィードバックは transcript を複数用意する、opus-5 判定の試行数を増やして信頼度を上げる。判定方法自体は Phase 3 と同じ（機械チェック + ブラインド A/B・順序入替）

## 影響範囲

- 調査のみ。アプリのコード・既定モデルは変更しない
- 採用時に想定される変更点（参考。実装タスク側で詳細化）:
  - 会話 LLM の抽象化: `ClaudeMessagesClient` は Anthropic 専用のため、OpenAI 互換クライアントの追加とプロトコル境界の整理が要る
  - `Usage/AIPricing.swift` の単価表と `docs/specs/ai-cost-map.md` の更新
  - API キー追加: Keychain + `.secrets/<provider>-api-key` + `run-*.sh` の seed 引数

## テスト方針

- 調査タスクのためアプリのビルド・テストは不要
- Phase 3 の実測は同一プロンプト・同一履歴で全モデルに投げ、レイテンシは各 3 回以上計測して中央値を採る
- 品質判定は `claude-opus-5` による LLM-as-judge（Phase 3 節の判定方法参照）+ 目視確認の併用とする
- 成果物: このプランへの比較表・実測値・結論の追記（完了後 `docs/plans/archive/` へ移動）

---

## Phase 1 調査結果（2026-07-31）

7 系統（DeepSeek / Qwen / Kimi / GLM / MiniMax / OpenRouter / 中国系音声）を並列調査した。**単価はすべて各社公式料金ページを 2026-07-31 に取得して確認済み**（出典は各節末尾）。比較基準は sonnet-5 = 入力 $3 / 出力 $15（〜2026-08-31 は導入価格 $2/$10 のため、9 月以降は節約幅がさらに広がる方向）。

### 単価サマリ（$ / 1M トークン、テキスト LLM）

| モデル | 入力 | 出力 | 対 sonnet-5（入 / 出） | キャッシュ読み | 学習利用 | データ所在 |
| --- | --- | --- | --- | --- | --- | --- |
| DeepSeek v4-flash | $0.14 | $0.28 | 1/21 / **1/54** | 入力の 2% | **あり**（PP に明記） | **中国本土** |
| DeepSeek v4-pro | $0.435 | $0.87 | 1/6.9 / 1/17 | 同上 | 同上 | 同上 |
| Qwen qwen-flash | $0.05 | $0.40 | **1/60** / 1/37 | ヒット 20%（explicit なら 10%） | **なし**（明記） | 東京 / SG 選択可 |
| Qwen qwen3.7-plus | $0.40 | $1.60 | 1/7.5 / 1/9.4 | 同上 | 同上 | 同上 |
| Qwen qwen3.7-max | $2.50（50% off 中 $1.25） | $7.50（$3.75） | 0.83 / 0.50 | 同上 | 同上 | 同上 |
| Kimi k2.6 | $0.95 | $4.00 | 1/3.2 / 1/3.8 | ヒット $0.16 | **あり得る**（オプトアウト明記なし） | SG |
| Kimi k3 | $3.00 | $15.00 | **1.0 / 1.0（同額）** | ヒット $0.30 | 同上 | SG |
| GLM-5.2 | $1.40 | $4.40 | 1/2.1 / 1/3.4 | $0.26 | **なし**（API 入力は保存自体しない） | SG |
| GLM-4.7 | $0.60 | $2.20 | 1/5 / 1/6.8 | $0.11 | 同上 | SG |
| GLM-4.5-Air | $0.20 | $1.10 | 1/15 / 1/13.6 | $0.03 | 同上 | SG |
| MiniMax M3（≤512K） | $0.30 | $1.20 | 1/10 / 1/12.5 | $0.06 | 明記なし（未確認） | **米国** |

### 各社メモ（会話アプリ観点）

#### DeepSeek（api-docs.deepseek.com）

- 現行は V4 世代のみ（`deepseek-v4-flash` / `deepseek-v4-pro`）。旧 `deepseek-chat` / `deepseek-reasoner` は 2026-07 に廃止済み
- **出力 1/54 の価格チャンピオン**。コンテキストキャッシュは全ユーザー自動（ヒット率保証なし）。**Anthropic 互換エンドポイント**（`api.deepseek.com/anthropic`）あり
- OpenAI 互換 + SSE。JSON mode はあるが **json_schema の strict structured outputs は無し**とみられる（feedback / topic / 翻訳経路に影響）
- **難点**: (1) 個人データは中国本土で処理・保存、学習利用あり（オプトアウト権の記載はあるが手順不明）。会話全文を送る本アプリでは重い。(2) 「ピーク時 2 倍課金」制を予告中（JST 10-13 / 15-19 時 = 日本の利用時間帯と丸被り）。(3) 公式 API の混雑遅延の報告多数
- 出典: https://api-docs.deepseek.com/quick_start/pricing / https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html

#### Alibaba Qwen（Model Studio 国際版）

- 現行 qwen3.7-max / qwen3.7-plus / qwen3.6-flash + 安定エイリアス qwen-max / -plus / -flash（旧スナップショット指しで単価が別）。tiered pricing は 256K 超からで本アプリには実質無関係
- **東京リージョンあり**（ap-northeast-1）— 中国系で唯一、ネットワーク RTT を国内水準にできる。決済はクレカ可（JCB 含む）
- **「データを学習に使わない」を公式ドキュメントに明記**。International 区分は選択リージョン内保存・推論一時データは非永続。準拠法はシンガポール法
- **Anthropic 互換エンドポイントあり**（`.../apps/anthropic`）。explicit キャッシュは Claude と同型の `cache_control: {"type": "ephemeral"}`（作成 125% / ヒット 10% / TTL 5 分）→ **既存 `ClaudeMessagesClient` の流用可能性が最も高い**
- JSON mode はあり。OpenAI 型 json_schema strict は記載なし（未確認）→ Phase 2 で確認
- 無料枠: モデルごと 100 万トークン / 90 日 → **Phase 2 の検証はほぼ無料でできる**
- 英語品質: qwen3.7-max が LMArena Text 13 位圏（三次情報）。英語固定運用での言語安定性は実測要
- 出典: https://www.alibabacloud.com/help/en/model-studio/model-pricing / https://www.alibabacloud.com/help/en/model-studio/what-is-model-studio / https://www.alibabacloud.com/help/en/model-studio/context-cache

#### Moonshot Kimi（platform.kimi.ai）

- kimi-k2 系は廃止済み。フラッグシップ **k3 は sonnet-5 と同額（$3/$15）で乗り換え意味なし**。廉価枠は k2.6（1/3 強）
- OpenAI 互換 + SSE + structured outputs（独自 MFJS スキーマ。**k2.6 は複雑スキーマで不安定と公式明記**）
- プライバシーポリシーはユーザーコンテンツを「モデル最適化」に使うと記載、API のオプトアウト明記なし
- 英語ライティング評価は高い（EQ-Bench Creative 2 位）が、会話用途では「冗長」の評判が一貫
- **判定: 見送り**（価格・ポリシー・冗長癖のいずれも決め手を欠く）
- 出典: https://platform.kimi.ai/docs/pricing / https://platform.kimi.ai/docs/agreement/userprivacy.md

#### Zhipu GLM（Z.ai 国際版）

- 現行 GLM-5.2（$1.40/$4.40）。廉価枠 GLM-4.7（$0.60/$2.20）/ GLM-4.5-Air（$0.20/$1.10）
- **「API 経由のコンテンツは保存しない」= 学習不使用が最も明確**。SG 法人・SG 処理
- OpenAI 互換 + SSE + tool calling + structured outputs 対応（公式明記）。implicit キャッシュ（ヒット約 18%、保存料は期間限定無料）
- 強みはコーディング / エージェント寄り（LMArena Code Frontend 2 位）。Text Arena 総合は 25 位前後で**雑談品質は一段落ちる前提で実測要**
- 注意: 決済は**3DS 非対応**と公式 FAQ に明記 → 日本発行カードで失敗する可能性。AWS Bedrock / Vertex AI 経由でも提供あり
- 出典: https://docs.z.ai/guides/overview/pricing / https://docs.z.ai/legal-agreement/privacy-policy / https://docs.z.ai/help/faq

#### MiniMax（platform.minimax.io）

- 現行 M3（$0.30/$1.20、恒久 50% off 後）。**データは米国 DC 保存**・SG 法人・SG 法準拠。学習利用は否定条項が見つからず未確認
- OpenAI 互換 + **Anthropic 互換**エンドポイント + SSE。ただし **M 系は structured outputs 実質非対応**（json_schema は旧 Text-01 のみ）+ interleaved thinking で `reasoning_content` が混ざる → 文単位 TTS パイプラインに分離処理が要る
- エージェント特化の位置づけで、英会話相手としての品質評判は皆無（実測必須）
- 出典: https://platform.minimax.io/docs/guides/pricing-paygo.md / https://www.minimax.io/platform/protocol/privacy-policy

### OpenRouter（検証ハブ）

- 単価は**プロバイダのパススルー（上乗せなし）**。コストはクレジット購入時の手数料のみ（カード 5.5%・最低 $0.80）
- 5 系列すべて掲載。`provider.only` / `ignore` でルーティング先を固定でき、`zdr: true` で ZDR エンドポイント限定も可。**ZDR ≠ 非中国**な点に注意（本家 Moonshot 等も ZDR 一覧に含まれる）— 中国系事業者を避けるなら `only` で米系（DeepInfra / Fireworks / Together 等）を明示
- OpenRouter 自体はデフォルトでプロンプト非保存・学習利用なし（オプトイン制）
- structured outputs / caching はエンドポイント単位でパススルー対応（`/api/v1/models/{slug}/endpoints` で対応可否・レイテンシ統計を確認できる）
- 制約: qwen3.7-max / plus 等のプロプライエタリ Qwen は Alibaba 本家ルートのみ。**レイテンシ実測はルーティングで経路が変わるため `provider.only` 固定が必須**。OpenRouter 自体の追加レイテンシは公式未公表
- 出典: https://openrouter.ai/docs/faq / https://openrouter.ai/docs/features/provider-routing

### 中国系音声モデル（簡易）

LLM より効く可能性を確認した。**TTS / STT とも Alibaba が本命**（詳細と全比較表は調査ログ参照。単価は国際版公式ページ確認済み）。

| 経路 | 現行 | 中国系候補 | 換算 | 差 |
| --- | --- | --- | --- | --- |
| TTS | Gemini 3.1 Flash TTS ≈ $0.03/分 | Alibaba qwen3-tts-flash-realtime（$0.13/1 万字） | ≈ $0.0098/分 | **約 1/3** |
| STT | gpt-live-transcribe $0.017/分 | Alibaba qwen3-asr-flash-realtime（$0.000090/秒） | $0.0054/分 | **約 1/3** |

- qwen3-asr-flash は HF Open ASR Leaderboard 1 位（WER 4.25%）の評があり英語精度は有望。TTS の英語ネイティブらしさは実聴確認が必要（最新 qwen-audio-3.0-tts-flash $0.15/1 万字 ≈ $0.011/分 は TTS Arena 首位の報道あり）
- MiniMax speech 系は品質評判最良だが $0.045/分と現行より**高い**。BytePlus TTS は $0.0225/分で 25% 減どまり。→ 安さ目的なら Alibaba 一択
- Alibaba は WebSocket リアルタイム版があり現行パイプライン（文単位 TTS / ストリーミング STT）に載せられる形。**無料枠（TTS 11 万字・ASR 10 時間 / 90 日）で検証コストゼロ**
- → 有望なため、採否判断後に**別タスク「Alibaba 音声モデル（Qwen3-TTS / Qwen3-ASR）の実機検証」を起こす**（このタスクの Phase 2/3 は LLM に集中する）
- 出典: https://www.alibabacloud.com/help/en/model-studio/model-pricing / https://platform.minimax.io/docs/guides/pricing-paygo / https://docs.byteplus.com/en/docs/byteplusvoice/TTS_Billing

### コスト概算の当たり（Phase 4 で精緻化）

15 分 / 30 ターンの概算例（現行 $0.52/セッション）を仮に置き換えた場合:

- 会話 + フィードバックを qwen3.7-plus に置換: LLM $0.28 → 約 $0.03〜0.04 → **セッション約 $0.27**
- さらに TTS / STT も Alibaba に置換: $0.15+$0.09 → 約 $0.05+$0.03 → **セッション約 $0.12〜0.13（現行の 1/4）**
- 周辺経路（トピック・記憶ノート・翻訳）だけの置換は $0.01〜0.02 の節約にしかならず、単体では割に合わない（プラン冒頭の懸念どおり）

### Phase 3（実測）の具体化（候補絞り込み）

**候補は 3 つに絞る:**

1. **Qwen qwen3.7-plus（+ 参考で qwen-flash）** — 本命。価格 1/7.5〜1/60・学習不使用明記・東京リージョン・Anthropic 互換 + 同型キャッシュで実装コスト最小・無料枠で検証無料
2. **GLM-4.7（+ 参考で GLM-5.2）** — 対抗。学習不使用が最も明確・structured outputs 公式対応。雑談品質と日本からのレイテンシが未知数
3. **DeepSeek v4-flash（OpenRouter 経由・米系ホスト `provider.only` 固定）** — 価格基準点。本家 API はデータポリシー（中国本土保存 + 学習利用）で会話経路には不採用とし、米系ホスト経由の品質・単価だけ確認する

Kimi は見送り（上記判定）。MiniMax M3 は structured outputs 欠如と reasoning_content 分離の実装コストから優先度を下げ、OpenRouter で品質だけ横目で見る程度とする。

必要なアカウント / キーの用意は **Phase 2（API キー収集）** として切り出した（対応方針の Phase 2 節参照。Alibaba Model Studio + OpenRouter の 2 つ、Z.ai 直は保留）。

## Phase 2 実施記録（2026-07-31）

アカウント 2 つ・キー 2 本を用意し、両方とも curl での疎通確認に成功。**Phase 2 完了**。

- **Alibaba Cloud（国際版）**: アカウント作成 → Model Studio はコンソール初回アクセスで明示的な有効化画面なしに利用可能になっていた。API キー（Singapore / Default Workspace）を `.secrets/dashscope-api-key` に配置。`https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions` へ `qwen-flash` で疎通 OK（消費 14 トークン、無料枠内）
- **OpenRouter**: アカウント作成（Google ログイン）→ クレジット $5 購入 → キーを `.secrets/openrouter-api-key` に配置。`z-ai/glm-4.7` で疎通 OK（$0.000204）

Phase 1 の想定から更新した事実:

- **Model Studio の無料枠（モデルごと 100 万トークン）はシンガポールリージョン限定**。API キー・モデルリスト・エンドポイントはリージョンごとに別で相互流用不可。東京リージョン（ap-northeast-1）はワークスペース専用ドメイン `{WorkspaceId}.ap-northeast-1.maas.aliyuncs.com` のみ（DashScope ドメイン・トライアルとも非対応）→ **品質検証はシンガポール無料枠で行い、東京は Phase 3 のレイテンシ実測時に日本リージョンのワークスペース + 専用キーを別途作って少額課金で使う**（出典: https://www.alibabacloud.com/help/en/model-studio/regions/ ）
- **GLM-4.7 は OpenRouter 経由で reasoning が既定 ON**。「OK」と返すだけの疎通リクエストで reasoning 87 トークンを出力した（出力 90 トークン中）。会話ターン用途ではレイテンシ・コストに直結するため、**Phase 3 では reasoning の抑制（OpenRouter の `reasoning` パラメータ）を必ず検証項目に入れる**
- OpenRouter のモデル一覧に `qwen/qwen3.7-plus` / `qwen3.7-max` / `deepseek/deepseek-v4-flash` / `minimax/minimax-m3` の掲載を確認済み（Qwen のルーティング先が Alibaba 本家のみである点は Phase 1 記載どおり）

**Phase 3 の追加確認項目**（調査で未確認だったもの）:

- Qwen Anthropic 互換エンドポイントで既存リクエスト形（system cache_control / streaming / max_tokens / effort 系パラメータの受容）がそのまま通るか
- Qwen / GLM の structured outputs（json_schema 相当）がフィードバック生成の出力形式を安定して満たすか
- 英語固定（2 キャラ台本 system prompt）で中国語・ピンイン混入が起きないか
- GLM / DeepSeek（OpenRouter 経由）で reasoning を抑制した場合の品質・レイテンシ・コスト（既定 ON のままでは会話ターンに不向き。Phase 2 実施記録参照）

## Phase 3 実施記録（2026-07-31）

scratchpad の node スクリプトで実施（コードはアプリに入れていない）。**Phase 3 完了**（東京リージョンのレイテンシ実測のみ任意の積み残し。下記）。

### 実施方法とプランからの逸脱

- 本番と同一の system prompt（`CoachSystemPrompt` 7,918 字 / `SessionFeedbackClient.systemPrompt` 2,046 字を Swift で評価して抽出）・同一のリクエスト形（会話: effort low / max_tokens 1024 / stream / cache_control、フィードバック: effort high / max_tokens 16000 / json_schema）を全モデルに使用
- **逸脱**: 実機の実セッションは Mac から取得できず、シミュレータには開発テストの短いセッションしか無かった。会話は実セッション #12（ラーメン雑談）を土台に、カバレッジ用の合成ケース（日本語切替・[Memory]+[New topic] 開幕）を明示して追加。フィードバックの品質比較は実セッション文体に合わせた合成 transcript（学習者 8 ターン・典型的な日本人学習者の誤りを含む）を使用し、形式安定性は実セッション #12 でも確認した
- ケースは 4 つ: `continue`（通常ターン）/ `goodbye`（別れの挨拶 → [end]）/ `japanese`（学習者が日本語に切替）/ `newtopic`（記憶ノート付き開幕ターン）
- 判定はプランどおり: 機械チェック（タグ形式・発話数・最終行の質問・[end]・CJK/ピンイン混入）はスクリプト、主観品質は **claude-opus-5 の LLM-as-judge**（モデル名を伏せた A/B、提示順入替 2 回、勝敗が割れたら引き分け）で sonnet-5 と比較

### レイテンシ実測（会話ターン・日本から・4 回の中央値）

| モデル / 経路 | TTFT | 1 文確定 | 備考 |
| --- | --- | --- | --- |
| sonnet-5（基準） | 1,052ms | 1,353ms | cache read 2,453 tok |
| **qwen3.7-plus**（DashScope Anthropic 互換・SG・thinking 無効） | **852ms** | **1,164ms** | cache read 1,722 tok。**基準より速い** |
| qwen3.7-flash（同上） | 737ms | 901ms | 最速クラス |
| glm-4.7（OpenRouter → Z.AI 固定・reasoning 無効） | 2,151ms | 2,155ms | **実質ストリーミングせず全文一括着**（TTFT≈全体） |
| glm-5.2（同上） | 1,795ms | 1,795ms | 同上 |
| deepseek-v4-flash（OpenRouter → DeepInfra/Fireworks 固定・reasoning 無効） | 655ms | 1,468ms | TTFT 最速だが分散大（450〜1,255ms） |

- **Qwen は Anthropic 互換エンドポイントだと thinking が既定 ON で TTFT 20〜35 秒**になる。`thinking: {type: "disabled"}` を送ると上表のとおり 1 秒前後に解決（採用時はこのパラメータが必須。Claude と違い thinking 無効化の副作用は観測されなかった）
- SG リージョンで既に sonnet-5 より速いため、東京リージョン実測（日本リージョンのワークスペース + 専用キー作成が必要）は**任意**とした。実施する場合はアカウント作業がユーザー側に必要

### 会話品質

機械チェック（4 ケース中クリーンだった数と主な違反）:

| モデル | クリーン | 主な違反 |
| --- | --- | --- |
| sonnet-5（基準） | 2/4 | japanese で 3 発話、newtopic で**最終行の質問がタグ無し + 空行**（本番でも起きる癖と判明） |
| qwen3.7-plus | 2/4 | continue で 3 発話。**goodbye で [end] を出さず学習者を引き留めた**（明確な規約違反） |
| **qwen3.7-flash** | **4/4** | なし |
| glm-4.7 | 2/4 | **最終行の質問がタグ無しになる癖**（2/4 ケースで発生。台本パーサを壊すため実害最大） |
| glm-5.2 | 2/4 | continue で 3 発話、goodbye で空行 |
| deepseek-v4-flash | 1/4 | ほぼ毎ターン 3 発話（冗長癖） |

- **中国語・ピンイン・日本語の混入は全モデル・全ケースでゼロ**（懸念は解消）
- opus-5 判定（対 sonnet-5。順序入替 2 回一致のみ勝敗、不一致は tie）:

| 候補 | continue | goodbye | japanese | newtopic | 通算 |
| --- | --- | --- | --- | --- | --- |
| qwen3.7-plus | ✗ | ✗ | ○ | ○ | 2 勝 2 敗 |
| qwen3.7-flash | ✗ | ✗ | ○ | ○ | 2 勝 2 敗 |
| glm-4.7 | ✗ | ✗ | − | − | 0 勝 2 敗 2 分 |
| glm-5.2 | ✗ | ✗ | ○ | ○ | 2 勝 2 敗 |
| deepseek-v4-flash | ✗ | ✗ | ○ | ○ | 2 勝 2 敗 |

- 判定理由を読むと構図は明瞭: **自然な雑談の流れ（continue / goodbye）では全候補が sonnet-5 に一貫して負ける**（判定は sonnet の反応の温かさ・キャラらしさ・オープンな質問を繰り返し評価）。候補が勝った japanese / newtopic は **sonnet-5 側の出力がたまたま崩れたケース**（不自然な言い回し + 3 発話、タグ無し最終行）で、相対的に勝った側面が強い
- 各候補とも「英語で言い直してみて」の促し（日本語入力時の仕様）を省く傾向。qwen3.7-plus は goodbye 対応も外しており、**プロンプト追従の細部で sonnet-5 に一段劣る**。glm-4.7 はタグ無し癖 + 引き分け止まりで最下位評価

### フィードバック品質（structured outputs の安定性 + 内容）

| モデル / 方式 | スキーマ適合 | 生成時間 | opus-5 判定（対 sonnet-5） |
| --- | --- | --- | --- |
| sonnet-5（本番同一） | 3/3 | 11〜19 秒 | 基準 |
| **qwen3.7-plus**（**Anthropic 互換 + `output_config.format` json_schema がそのまま通った**） | 3/3 | 3〜9 秒 | 惜敗（7-8 / 7-7 tie。summary の具体性で劣る） |
| glm-4.7（OpenRouter **DeepInfra 固定**。Z.AI 経由は json_schema 非対応で 404） | 2/2 | 11〜27 秒 | 辛勝（angry with me 等コロケーション指摘を評価） |
| deepseek-v4-flash（OpenRouter 米系固定 json_schema） | 3/3 | 5〜8 秒 | **明確に勝ち**（9-7 / 7-9。summary の具体性・worth waiting 等の指摘を評価） |

- 4 モデルとも指摘は実際の学習者の誤りのみで、捏造・誤った文法解説は判定でも指摘されず。**フィードバック経路は品質面では置き換え可能**が実測の結論（判定が拾った sonnet-5 の弱点は summary 冒頭の「週末の週末」という重複タイポ）
- ただしサンプルは transcript 1 件 + 判定 1 ペアずつであり、差は小さい。採否の重み付けは Phase 4 で行う

### Phase 2 積み残し確認項目の結果

1. **Qwen Anthropic 互換エンドポイント**: 既存リクエスト形（system cache_control / streaming / max_tokens / effort / structured outputs の json_schema）を**全て受容**。cache_control は実際にヒット（cache_read_input_tokens が返る）。唯一の差分は thinking 既定 ON → `thinking: {type: "disabled"}` の追加が必要。**`ClaudeMessagesClient` / `SessionFeedbackClient` はエンドポイント・キー・モデル名 + thinking 1 行の差でほぼ流用可能**
2. **structured outputs の安定性**: Qwen（Anthropic 互換）・GLM（DeepInfra ホスト）・DeepSeek（米系ホスト）とも全回スキーマ適合。**GLM は Z.AI 本家経由だと OpenRouter 上で json_schema 非対応**な点だけ注意（z.ai 直叩きの仕様は未確認）
3. **中国語・ピンイン混入**: 全モデル・全ケースでゼロ
4. **reasoning 抑制（GLM / DeepSeek）**: OpenRouter の `reasoning: {enabled: false}` で reasoning_tokens=0 を確認。レイテンシ・コストとも会話ターンに使える水準（上表）。品質は抑制状態で計測した値がそのまま比較結果

## Phase 4 実施記録（2026-07-31）: 判断とまとめ

**Phase 4 完了**。判断は「Phase 5（厳密品質チェック）の通過を実装の条件とする」暫定判断として記録する（Phase 5 はユーザー指示で Phase 4 の後に追加されたため）。

### コスト再計算（15 分 / 30 ターンの概算例。[ai-cost-map.md](../specs/ai-cost-map.md) と同一前提）

会話 LLM とフィードバックを候補モデルに置き換えた場合（トークン数は現行例と同じ値を使用。Qwen のトークナイザは実測で system prompt が sonnet 比 約 0.7 倍だったので、実際はやや下振れする）:

| 経路 | 現行 sonnet-5 | qwen3.7-plus（$0.40/$1.60・キャッシュ読み 10%） | deepseek v4-flash（$0.14/$0.28） |
| --- | --- | --- | --- |
| 会話 LLM（履歴 45K + system キャッシュ 60K + 出力 3K） | $0.22 | **$0.03** | $0.01 |
| フィードバック（入力 5K + 出力 3K） | $0.06 | **$0.01** | $0.002 |

セッション合計（STT $0.09 + TTS $0.15 は現行のまま）:

| 置き換え範囲 | 1 セッション | 月額（毎日 1 セッション） | 節約 |
| --- | --- | --- | --- |
| 現行 | $0.52 | 約 $16 | — |
| フィードバックのみ → qwen3.7-plus | $0.47 | 約 $14 | **月 約 $1.5**（小さい） |
| 会話 + フィードバック → qwen3.7-plus | $0.28 | 約 $8.5 | 月 約 $7 |
| さらに TTS / STT → Alibaba（Phase 1 簡易調査の単価） | $0.12〜0.13 | 約 $4 | 月 約 $12（最大） |

- 会話・フィードバック以外の LLM 経路（トピック / 記憶ノート / 翻訳）は現行でも 1 セッション $0.01 前後であり、置き換えの節約は月 $1 未満。Phase 1 の懸念どおり単体では割に合わない
- sonnet-5 の導入価格（$2/$10）が 2026-09-01 に終わると現行コストは上がる方向（会話 + フィードバックで 1 セッション約 $0.28 → 実質、上表の節約幅はさらに広がる）

### 経路ごとの判断（Phase 5 通過を実装の条件とする）

| 経路 | 判断 | 根拠 |
| --- | --- | --- |
| 会話ターン | **保留**（現時点では置き換えない。Phase 5 で qwen3.7-plus / flash を再評価） | Phase 3 判定で自然な雑談の流れ（continue / goodbye）は sonnet-5 が一貫して勝ち。qwen3.7-plus は [end] 規約違反もあり、プロンプト追従の細部で一段劣る。音声レイヤ決定の決め手だった「会話相手の品質」に関わるため、月 $6 弱の節約では踏み切らない。レイテンシ（SG で sonnet より速い）と実装コスト（クライアント流用可）は確認済みなので、Phase 5 で品質が並べば置き換え候補に昇格 |
| フィードバック | **置き換える方向**（第一候補 qwen3.7-plus・Anthropic 互換経由。Phase 5 で最終確認後に実装タスクを起こす） | Phase 3 で品質は sonnet-5 と同等圏（qwen 惜敗 / deepseek 明確勝ち）、structured outputs 全回適合、生成時間は半分以下。節約は月 $1.5 と小さいが、実装が `SessionFeedbackClient` ほぼ流用ででき、リスクが最小の経路。deepseek は品質最良だが OpenRouter 依存（クレジット管理 + 米系ホスト固定運用）が増えるため対抗扱い |
| トピック生成 | **置き換えない** | 1 回 $0.01 未満で節約がほぼゼロ。会話ターンを将来置き換える場合に同一クライアントでまとめて移す |
| 記憶ノート | **置き換えない** | 同上（セッションごと 1 回・小規模） |
| 翻訳（haiku-4-5） | **置き換えない** | 訳 ON のときだけ・1 セッション $0.01 未満。節約対象として意味がない |
| GLM（全経路） | **見送り** | Phase 3 で判定最下位（0 勝）+ 最終行タグ無し癖（台本パーサ破壊）+ ストリーミング実質なし + Z.AI 経由は json_schema 非対応。価格も qwen3.7-plus に対して優位なし |
| TTS / STT | **別タスクへ**（LLM より節約が大きい） | Phase 1 簡易調査で Alibaba qwen3-tts / qwen3-asr が現行比 約 1/3 の単価・無料枠で検証可能。月 約 $5 の節約見込みで LLM 置き換えより効く。`TODO.md` に「Alibaba 音声モデル（Qwen3-TTS / Qwen3-ASR）の実機検証」を起こした |

### 補足（Phase 5 への申し送り）

- Phase 5 の評価対象: **qwen3.7-plus（会話 + フィードバック）/ qwen3.7-flash（会話の廉価候補）/ deepseek-v4-flash（フィードバックの対抗）**。GLM は対象外
- qwen3.7-flash の単価は未確認（Phase 1 で確認したのは qwen-flash 系列 $0.05/$0.40）。Phase 5 で flash を本命に上げる場合は料金ページで要確認
- 採用時の実装タスク（Keychain seed 追加・`AIPricing.swift` 単価表・`ai-cost-map.md` 更新・thinking 無効化パラメータ追加を含む）は Phase 5 の結果が出てから `TODO.md` に起こす
