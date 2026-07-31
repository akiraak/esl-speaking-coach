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
- 判定は目視のサイドバイサイド比較で良い（個人ツールなので自分の納得感が基準）

### Phase 4: 判断とまとめ

- [ai-cost-map.md](../specs/ai-cost-map.md) の概算例（15 分 / 30 ターン）を候補モデルの単価で再計算し、**1 セッション・月額でいくら下がるか**を出す
- 経路ごと（会話 / フィードバック / トピック / 記憶ノート / 翻訳）に「置き換える / 置き換えない / 保留」を決め、結論と根拠をこのプランに記録する
- 採用する場合は**実装タスクを別途 `TODO.md` に起こす**（このタスクは調査で完結）

## 影響範囲

- 調査のみ。アプリのコード・既定モデルは変更しない
- 採用時に想定される変更点（参考。実装タスク側で詳細化）:
  - 会話 LLM の抽象化: `ClaudeMessagesClient` は Anthropic 専用のため、OpenAI 互換クライアントの追加とプロトコル境界の整理が要る
  - `Usage/AIPricing.swift` の単価表と `docs/specs/ai-cost-map.md` の更新
  - API キー追加: Keychain + `.secrets/<provider>-api-key` + `run-*.sh` の seed 引数

## テスト方針

- 調査タスクのためアプリのビルド・テストは不要
- Phase 2 の実測は同一プロンプト・同一履歴で全モデルに投げ、レイテンシは各 3 回以上計測して中央値を採る
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

**Phase 3 の追加確認項目**（調査で未確認だったもの）:

- Qwen Anthropic 互換エンドポイントで既存リクエスト形（system cache_control / streaming / max_tokens / effort 系パラメータの受容）がそのまま通るか
- Qwen / GLM の structured outputs（json_schema 相当）がフィードバック生成の出力形式を安定して満たすか
- 英語固定（2 キャラ台本 system prompt）で中国語・ピンイン混入が起きないか
