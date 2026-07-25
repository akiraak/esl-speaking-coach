# 会話の流れと生成方法を決める（設計プラン）

## 目的・背景

`docs/specs/screen-layout.md` で画面レイアウトは決定済みだが、会話の中身を作る方式が未決のまま残っている。

- **AI 2 キャラのターン進行方式**（仕様書の未決事項筆頭。台本方式 / キャラ別呼び出し / メイン + 相槌固定の 3 候補）
- キャラの名前・人格・TTS voice の具体値
- トピック候補の生成方式（トピックカードの中身）
- セッション進行（開始 → 会話 → 終了）の詳細と、それを支える会話履歴モデル

本タスクはこれらを**決めて仕様書に落とす設計タスク**。本実装は既存 TODO（「会話画面の UI」「音声入出力の本実装」等）で行うが、方式の成立性に関わる最小限のスパイク検証（ストリーミングの speaker タグパース、TTS voice 切替）は本タスクに含める。

### キャラは ちょビ / なるこ を使う（ユーザー決定・2026-07-25）

キャラのペルソナと声は `claude-code-manager`（`/Users/akiraak/Projects/claude-code-manager/`）の 2 キャラ **ちょビ（Chobi）** と **なるこ（Naruko）** を移植する。原典:

- 正本: `claude-code-manager/ai-monitor/voice-persona.json`（コード側の既定値は `ai-monitor/src/persona.ts` の `DEFAULT_TEACHER` / `DEFAULT_STUDENT`）
- ちょビ: 先生役。落ち着いたトーン・ツッコミ気質・照れ屋。TTS voice **Leda**
- なるこ: 生徒役。明るく元気・素直・ボケとダジャレが隠し味（数会話に 1 回、連発禁止、すべったらちょビがツッコむ）。TTS voice **Aoede**

移植にあたっての前提:

- 原典は日本語の Twitch 配信実況用ペルソナ。本アプリは**英語会話のみ**なので、人格の骨格（先生×ツッコミ / 生徒×ボケ、掛け合いの温度感）を保ったまま**英語会話コーチ文脈のペルソナに翻案**する（そのままコピーはしない）
- voice の Leda / Aoede はどちらも Gemini prebuilt voice。本プロジェクトの TTS は Gemini Flash TTS（`GeminiTTSClient`、現行既定 voice は Aoede 単一）なのでそのまま使えるが、**発話ごとの voice 切替**が新規に必要
- `screen-layout.md` のモックにある仮名 Mia / Leo（アバター色 `#EF5DA8` / `#3D9BE9`）は Chobi / Naruko に置き換える

## 決定ログ（会話で決めた仕様。最終的に Phase 4 で仕様書へ転記する）

2026-07-25 決定分（Phase 1）:

- **役割分担**: ちょビ = 英会話の先生（会話を回す・recast / tip 担当）、なるこ = ユーザーと一緒に練習する仲間の生徒
- **名前表記**: UI 上は **Chobi / Naruko**（ローマ字）
- **アバター色**: Chobi = ピンク `#EF5DA8`（モックの色を流用）、Naruko = **薄い緑**（仮 `#6FCF97`。具体値は UI 実装時に案 D パレットとの調和で微調整可）
- **なるこの英語**: レベル設定はしない（普通の自然な英語。学習者風のミスはさせない）
- **笑い要素**: ボケ + ダジャレは英語の言葉遊び（簡単な pun）に翻案。頻度ルールは原典を踏襲（隠し味: 数会話に 1 回・1 会話に最大 1 つ・連発禁止・すべったら Chobi が軽くツッコむ）
- **架空設定**: 2 キャラとも軽い架空の日常（好み・趣味レベル）を持たせ、日常系トピックで雑談が弾むようにする。原典の「身体体験を捏造しない」ルールは引き継がない

**Phase 1 完了（2026-07-25）**。英語ペルソナドラフト承認済み:

- Chobi: 先生役。落ち着いたトーン・相手の話に本気で興味・軽いツッコミ・照れ屋。recast / tip 担当（既存 correction policy 踏襲）。好み: 猫・コーヒー・ミステリー小説。TTS スタイル: "Read aloud in a warm, calm, gently cheerful voice, like a friendly teacher smiling as she talks."
- Naruko: 仲間の生徒。明るく元気・素直・たまにズレた質問・簡単な英語 pun が隠し味（数会話に 1 回・1 会話最大 1 つ・すべったら Chobi がツッコむ）。Chobi より短め、質問と相槌中心。好み: ラーメン・カラオケ・スマホゲーム。TTS スタイル: "Read aloud in a bright, energetic voice, full of curiosity, like an enthusiastic student chatting with friends."
- 原典の emotions マップと AI 正直ルールは移植しない

**Phase 2 の進め方（2026-07-25 ユーザー指示）**: 仮トピックを 3 個作り、台本方式（行頭 `Chobi:` / `Naruko:` タグ）で実際に会話を仮生成して問題ないか確認しながらターン進行方式を詰める。

**Phase 2 仮生成検証（2026-07-25 実施）**: 仮トピック 3 個（Planning a trip / Food you can't quit / Your morning routine）× recast・短文回答・詰まり・語彙質問のシナリオで `claude-opus-5`（effort low, max_tokens 1024, 非ストリーミング）を実呼び出し。成果物は `docs/plans/archive/spike-conversation/`（`group_system_prompt.txt` = 2 キャラ台本 system prompt ドラフト、`turn_spike.py` = 検証スクリプト）。

- 結果: 行頭タグ 100% 遵守・ナレーション等の混入なし。recast、詰まり救済（具体例→選択式質問）、語彙質問への短答→会話復帰、ペルソナ表出をすべて確認。キャッシュ有効（system 約 1.8k トークン）、出力 48〜99 トークン/ターン
- **決定: 発話数ルール** — トピック開始ターンは 2〜3 発話可（2 キャラの場作り）、通常ターンは 1〜2 発話厳守
- **決定: 質問ルール** — 学習者が答えるべき質問はターン末尾に 1 つだけ（最後に話すキャラが担当）。リアクションとしての修辞的疑問文は可とする
- **決定: ターン進行方式は台本方式で確定**（2026-07-25。キャラ別呼び出し・メイン+相槌固定は不採用。1 呼び出しで行頭 `Chobi:` / `Naruko:` タグ付き台本を生成）
- **決定: barge-in 時の台本確定ルール** — 吹き出しは発話単位で読み上げ開始時に表示。割り込まれたら読み上げ中の発話までを会話履歴に確定し、未読み上げの発話は履歴・UI ともに破棄する（AI は「言っていないこと」を覚えていない状態にする）

**Phase 2 技術スパイク（2026-07-25 実施。スクリプトは `docs/plans/archive/spike-conversation/`）:**

- ストリーミング speaker タグパース（`stream_spike.py`）: Claude SSE デルタを speaker 対応 SentenceChunker（Python 移植）に逐次投入し、(speaker, 文) を文確定ごとに取り出せることを確認。タグ誤認・UNTAGGED 行なし。最初の文確定まで 2.1〜2.9 秒、ターン全文 3.1〜3.7 秒（effort low・キャッシュ有効時）
- Gemini TTS voice 切替（`tts_spike.py`）: 発話ごとに `voiceName` を Chobi=Leda / Naruko=Aoede で切り替えるリクエストで英語音声を生成。最初の音声チャンクまで 0.69〜0.94 秒。キャラ別スタイル前置文も適用。Swift 実装は `GeminiTTSConfiguration` の voice / styleInstruction を発話の speaker で切り替える形になる
- **決定: voice とスタイル指示文を確定**（2026-07-25 ユーザー試聴済み）。Chobi = Leda + "Read aloud in a warm, calm, gently cheerful voice, like a friendly teacher smiling as she talks:" / Naruko = Aoede + "Read aloud in a bright, energetic voice, full of curiosity, like an enthusiastic student chatting with friends:"。微調整は TODO「モデル・パラメータの最終調整」で扱う

**Phase 2 完了（2026-07-25）**

**Phase 3 決定（2026-07-25。検証は `docs/plans/archive/spike-conversation/topic_spike.py`）:**

- **トピックの渡し方**: system prompt には入れず（キャッシュ保護）、会話履歴の先頭 user メッセージとして `[New topic: <トピック名>]` 制御メッセージで渡す
- **セッション開始**: トピック選択 → AI 側から開始（開始ターン 2〜3 発話 + starter question）。現行 `CoachSystemPrompt` の「learner speaks first」は廃止
- **会話履歴モデル**: `ConversationMessage` に speaker（user / chobi / naruko）を追加。Claude へは assistant ターンにタグ付き台本原文を入れ、表示時に speaker 別吹き出しへ分解する
- **トピック候補の形式**: 英語タイトル（3〜6 語）+ フック 1 文（12 語以内）。トピックカードのピル表示にフック文が加わるため `screen-layout.md` のカードレイアウトに軽微な変更（Phase 4 で注記）
- **トピック生成方式**: 会話とは別の軽量呼び出し。`claude-opus-5` / structured outputs（`topics: [{title, hook}]` の json_schema）/ effort low / 非ストリーミング。コンテキストに直近トピックのタイトル一覧を渡して重複回避（🔄 再生成時は表示中の候補も除外リストへ）。「Free talk」は生成せずアプリ側で固定候補として追加。呼び出しタイミングは screen-layout の決定どおり（初回起動時 / セッション終了直後 / 🔄 タップ時）
- **セッション終了トリガ**: 手動（ヘッダメニュー）+ goodbye 自動終了。学習者が明確に終了意思を示したときのみ、AI が closing 発話の後に制御行 `[end]` を単独行で出力し、アプリが検知してセッション終了 → フィードバック生成へ。`[end]` は UI 非表示・TTS 非再生・永続化時は除去
- 検証結果: トピック生成は過去トピックと重複しない 3 候補（ジャンル・難易度が分散）を structured outputs で取得（出力 110 トークン）。`[end]` は明確な goodbye でのみ出力され、「昼時になった」等の時間言及や「別の話題にしたい」では出力されないことを確認（後者はキャラが会話内で自然に話題転換した）

**Phase 3 完了（2026-07-25）**

**追加決定（2026-07-25）: 会話生成モデルは `claude-sonnet-5`**

- 3 モデル比較（`model_compare_spike.py`、記録 `model-compare-transcripts.md` / `model_compare_result.txt`）: 最初の文確定までの平均が opus-5 約 2 秒（外れ値除く）/ sonnet-5 約 1.6〜1.8 秒 / haiku-4-5 0.85 秒。品質は opus ≥ sonnet ≫ haiku（haiku はペルソナ表出がほぼ消え「相手感」が失われるため不採用）
- sonnet-5 の逸脱 2 点はプロンプト強化で解消: ①チャットスラング禁止（"lol" 等の TTS 読み上げ事故防止）②「ターンの最終行 = 学習者への唯一の質問」の機械的ルール化 ③開始ターンの構成手順（感想 → リアクション → 最終行で starter question）を明示。最終検証 5/5 ターン合格（`sonnet5_verify_result.txt`）。詰まり救済で Chobi が Naruko に質問を振って手本を見せる好挙動も確認
- トピック生成も `claude-sonnet-5`（structured outputs 動作確認済み・約 3.6 秒、`topic_sonnet_check.py`）。会話後のフィードバック生成は `claude-opus-5` のまま
- CLAUDE.md の技術スタック表・音声レイヤ表・API 規約（モデル・サンプリング・thinking・キャッシュ最小プレフィックス 1024）を更新済み

## 対応方針

### Phase 1: キャラ確定（ちょビ / なるこの移植）

決めること:

1. **役割設定**: ちょビ = 英会話の先生（会話を回し、recast や tip を担う）、なるこ = 一緒に練習する仲間の生徒（ユーザーと同じ学習者目線で反応し、会話に厚みを出す。ボケ・言葉遊び担当）を基本線に、ESL グループトークとしての役割分担を文章化する
2. **英語ペルソナ文**: 原典の性格・話し方・笑いのルール（頻度制御含む）を英語会話用に書き直す。CLAUDE.md の規約どおり**固定文**とし、`cache_control` でキャッシュが効く形（512 トークン以上の固定プレフィックス）に収める
3. **表記・ビジュアル**: UI 上の名前表記（英語会話画面なので "Chobi" / "Naruko" のローマ字表記を基本線に検討）、アバター色の割り当て（モックの 2 色を流用するか）
4. **voice 確認**: Leda / Aoede は原典では日本語読み上げで使っていたため、**英語読み上げでの聞こえ方**をシミュレータで確認する（`ttsStyle` に相当するスタイル前置文も英語用に作り直す）。問題があれば voice 変更はモデル・パラメータ調整タスク側で扱う

### Phase 2: ターン進行方式の決定

`screen-layout.md` の 3 候補を比較し決定する。**推奨は台本方式**（先行事例: claude-code-manager が同じ 2 キャラで台本方式 — 1 回の LLM 呼び出しで speaker タグ付き 2〜4 発話の掛け合いを生成 — を運用済み）。

| 候補 | 長所 | 短所 |
| --- | --- | --- |
| 台本方式（1 呼び出しで両キャラ 0〜2 発話） | レイテンシ・コスト最小。掛け合い（ボケ→ツッコミ）を 1 呼び出し内で完結できる | speaker タグをストリーミング中にパースする実装が必要 |
| キャラ別呼び出し（キャラごとに別 system prompt） | 人格の独立性が最も高い | コスト・レイテンシ約 2 倍。掛け合いのテンポが作りにくい |
| メイン + 相槌固定 | 実装最小 | なるこが定型相槌になり、キャラを使う意義が薄い |

台本方式で検証・設計すること:

1. **出力フォーマット**: 行頭 speaker タグ（例: `Chobi: ...` / `Naruko: ...`）を基本線に検討する。structured outputs（`output_config.format`）も候補だが、文単位 TTS に流すには**ストリーミング途中で文が切り出せる**ことが必須のため、逐次パース可能な行タグ形式が有利。タグ欠落時のフォールバック（既定 speaker に帰属）も決める
2. **スパイク検証（成立性の確認・使い捨てで良い）**:
   - 2 キャラ台本の system prompt で実際に Claude をストリーミング呼び出しし、行タグが安定して出るか・`SentenceChunker` を speaker 対応に拡張して文単位に切り出せるかを確認する
   - `GeminiTTSClient` に発話ごとの voice 指定を渡し、Leda / Aoede を交互に再生してレイテンシと聞こえ方を確認する（`SentenceTTSClient` 境界に speaker を通す）
3. **発話量の制御**: 毎ターン両キャラが話すと user の発話量（本アプリの第一目的）を圧迫する。「基本は 1 キャラ 1〜2 文で応答、掛け合いはときどき（0〜2 発話）」「質問で締めるのはどちらか 1 人」等のルールを system prompt に落とす
4. **barge-in との整合**: 2 発話台本の読み上げ途中で割り込まれた場合、残り発話のキャンセルと会話履歴への確定範囲（どこまで「言ったこと」にするか)を決める

### Phase 3: トピック生成・セッション進行・会話履歴モデルの設計

1. **トピック生成**: 会話ターンとは別の軽量 Claude 呼び出しで候補 3 件を生成する
   - 出力は structured outputs で固定（候補タイトル + 導入のフック 1 文程度を想定）。非ストリーミングで良い。`effort: low`・小さい `max_tokens`
   - 呼び出しタイミング: 初回起動時 / セッション終了直後 / 「🔄 他の候補」タップ時（`screen-layout.md` の決定どおり）
   - 過去に出したトピック・直近セッションの話題を重複回避のコンテキストとして渡す（永続化タスク完了までは同一起動内のメモリで可）
2. **セッション進行の詳細**:
   - 開始: トピック選択 → 区切りシステムメッセージ → **AI 側から開始**（どちらかのキャラがトピックの導入 + 簡単な質問を 1 つ）を基本線に検討する。現行 `CoachSystemPrompt` は「learner speaks first」だが、トピックカード起点の UX では AI が口火を切る方が自然
   - トピックの渡し方: **system prompt には入れない**（キャッシュが割れる）。会話履歴側の先頭メッセージとして渡す形式を設計する
   - 終了: 「トピックを終える」→ フィードバック生成（別タスク）→ 次のトピックカード。会話途中でユーザーが goodbye した場合の扱いも決める
3. **会話履歴モデル**: `ConversationMessage` に speaker（キャラ識別子。user / chobi / naruko）を追加する方針を決める。Claude へ送る際の履歴の直列化（assistant ターンに行タグ付き本文をどう詰めるか）と、SwiftData 永続化（別タスク）から参照される形をここで確定する

### Phase 4: 仕様書化と後片付け

1. 決定内容を **`docs/specs/conversation-design.md`** に新規作成してまとめる（キャラ定義・ターン進行方式・プロンプト構成・トピック生成・セッション進行・履歴モデル）
2. `docs/specs/screen-layout.md` の未決事項（ターン進行方式・キャラ具体値）に決定への参照を追記し、モックの仮名 Mia / Leo の扱いを注記する
3. 本プランを `docs/plans/archive/` へ移動し、TODO の親項目を `DONE.md` へ

## 影響範囲

本タスクの成果物は仕様書のみ（スパイクコードは使い捨て可）。ただし後続実装で触ることになる箇所を設計時に意識する:

- `EslSpeakingCoach/Claude/CoachSystemPrompt.swift` — 1 コーチ人格 → 2 キャラ台本生成プロンプトへ全面書き換え
- `EslSpeakingCoach/Conversation/ConversationModels.swift` — speaker 追加
- `EslSpeakingCoach/Voice/SentenceChunker.swift` / `CloudPipeline/SentenceTTSClient.swift` / `CloudSentenceSpeaker.swift` / `GeminiTTSClient.swift` — speaker タグパースと発話ごとの voice 切替
- `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift` — 台本（複数発話）の順次読み上げと barge-in キャンセル
- トピック生成クライアント（新規）

## テスト方針

- Phase 2 のスパイクで「台本方式 × ストリーミング × 文単位 TTS × voice 切替」の成立を実際の API で確認してから方式を確定する（机上決定にしない）
- speaker タグパース（`SentenceChunker` 拡張案）は使い捨てにせず残す場合、既存 `SentenceChunkerTests` に倣ったユニットテストを付ける
- 仕様書には `screen-layout.md` と同様に受け入れ条件（後続実装タスクの確認項目）を列挙する
