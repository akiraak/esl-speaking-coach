# 使用モデルを管理画面から切り替え可能にする + 管理画面の整理 — 実装プラン

## 目的・背景

現在、AI モデルは**コードのハードコードか DEBUG 起動引数でしか切り替えられない**。
実機で「会話ターンを opus-5 にしたらどう変わるか」「TTS を Qwen に戻すと聞き心地はどうか」を
試すたびに、`./run-install-iphone.sh` で再インストールが要る（起動引数のあるものはまだマシで、
Claude 系 5 経路は**コード変更 + 再ビルドが必須**）。

作者専用ツールなので、**管理画面から選んで次のセッションから反映**できれば比較が一気に楽になる。
同時に、管理画面のタブが 5 つ（会話 / 記憶 / 料金 / 診断 / 容量）まで増えていて、
6 つ目の「モデル」を segmented picker に足すのは iPhone 幅では破綻する。**情報設計から整理する。**

## 現状整理（切替対象の棚卸し）

`AIUsageEvent.Kind`（課金 7 経路）と切替対象はちょうど 1:1 で対応する。**この対応を軸に設計する。**

| Kind | 経路 | 現在の既定 | 定義箇所（正） | 切替候補 |
| --- | --- | --- | --- | --- |
| `turn` | 会話ターン | `claude-sonnet-5` | `ClaudeMessagesClient.swift:60`（`TurnParameters.model`） | sonnet-5 / opus-5 / haiku-4-5 |
| `topic` | トピック生成 | `claude-sonnet-5` | `TopicSuggestionClient.swift:132`（body に直書き）+ `:190`（usage） | 同上 |
| `feedback` | フィードバック生成 | `claude-sonnet-5` | `SessionFeedbackClient.swift:60`（`static let model`） | 同上 |
| `memory` | 記憶ノート更新 | `claude-sonnet-5` | `MemoryUpdateClient.swift:150`（body）+ `:118`（usage） | 同上 |
| `translation` | 会話の翻訳 | `claude-haiku-4-5` | `TranslationClient.swift:144`（body）+ `:192`（usage） | 同上 |
| `tts` | 読み上げ | Gemini 3.1 Flash TTS | `SentenceTTSClientFactory.swift:16`（`Configuration.provider`） | Gemini / Qwen（/ OpenAI） |
| `stt` | 音声認識 | `gpt-live-transcribe` | `OpenAITranscriptionProtocol.swift:11`（`model`） | gpt-live-transcribe / gpt-4o-transcribe / qwen3-asr-flash-realtime |

**現在の切替手段**: TTS は `-tts-provider`、STT は `-stt-model` / `-stt-delay` の DEBUG 起動引数のみ。
Claude 系 5 経路は起動引数すら無い。

## 設計方針

### 1. モデル選択の単一の正 — `Settings/ModelSettingsStore.swift`（新規）

- `@MainActor` の `@Observable` クラス。保存先は **UserDefaults**（端末内・キー `model.<kind.rawValue>`）
- **既定値はコード側（各クライアント / Configuration）が持ち続ける**。ストアは
  「保存値があればそれ、無ければコード既定」を返すだけにする
  （`SentenceTTSClientFactory.Configuration` で確立した「既定は 1 箇所」という現在の方針を崩さない）
- 未知の rawValue（廃止したモデル名が残っている等）は既定へフォールバックする
  （`PracticeMode(storedValue:)` と同じ正規化パターン）

### 2. 選択肢の定義 — `Usage/AIRouteModel.swift`（新規、`AIPricing` と同居させる）

経路ごとの「選べるモデル一覧・表示名・既定・補足」を 1 箇所に集める。
**`AIUsageEvent.Kind` をキーにする**ので、料金画面の種別内訳とそのまま噛み合う。

Claude 側の制約はここに畳み込む（プロバイダ SDK が無く raw HTTP なので、こちらで守る必要がある）:

- **`output_config.effort` の可否がモデルで違う**。`claude-haiku-4-5` は effort を送ると **400**
  （既に `TranslationClient.swift:26` にコメントあり）。`claude-sonnet-5` / `claude-opus-5` は
  `low`〜`max` を受ける。→ `supportsEffort` を持たせ、**リクエスト組み立て側は
  「効かない組み合わせなら effort フィールドごと落とす」1 本の分岐で処理する**
  （現在 effort は 会話ターン=low / トピック=low / 記憶=medium / フィードバック=high / 翻訳=送らない）
- **プロンプトキャッシュの最小プレフィックスがモデルで違う**（2026-08-03 時点）:
  `claude-opus-5` 512 / `claude-sonnet-5` 1024 / `claude-haiku-4-5` **4096** トークン。
  2 キャラ台本の system prompt は約 2,000 トークンなので、**会話ターンを haiku-4-5 にすると
  `cache_control` が黙って効かなくなる**（エラーは出ず、ただ課金が増える）。
  → 選択 UI にこの注記を出す。`CoachSystemPrompt.swift:6` / `QuizCoachSystemPrompt.swift:16` の
  コメントも「sonnet-5 は 1024」固定の書き方をやめる
- `claude-opus-5` は **thinking が既定で ON**（未指定＝adaptive）。本プロジェクトは元々
  thinking を無効化しない方針（CLAUDE.md）なので追加の変更は不要だが、
  **`max_tokens` は thinking + 本文の合計に掛かる**ため、会話ターンの 1024 は opus-5 では
  途中で切れうる。opus-5 選択時は会話ターンの max_tokens を引き上げる（実測して決める）

### 3. 注入の経路

- ハードコードしている 3 クライアント（`TopicSuggestionClient` / `MemoryUpdateClient` /
  `TranslationClient`）に `model`（+ effort）を持つ `Parameters` を生やし、
  `ClaudeMessagesClient.TurnParameters` / `SessionFeedbackClient.model` と形を揃える
- 呼び出し元（`ChatRoomStore` / `TurnBasedVoiceSession`）が `ModelSettingsStore` から読んで詰める。
  `ChatRoomStore.launchSession`（`:720`）と `currentTTSConfiguration`（`:1134`）が既に
  「構成を組み立てる 1 箇所」になっているので、そこに寄せる
- **優先順位は `DEBUG 起動引数 > 管理画面の保存値 > コード既定`**。
  起動引数は E2E 用に生かす（`currentTTSConfiguration` の既定上書きバグの反省どおり、
  **override があるときだけ**上書きする）

### 4. 反映タイミング

- **セッション中は変えない**。TTS / STT は `TurnBasedVoiceSession` の init で
  クライアント生成・マイクのサンプルレート決定（OpenAI 24kHz / Qwen3-ASR 16kHz）まで済むので、
  途中差し替えは音声レイヤの再構築が必要になる。**次のセッション開始から反映**とし、UI に明記する
- Claude 系（会話ターン以外）はリクエスト単位なので次の呼び出しから効くが、
  **挙動を揃えるため「次のセッションから」で統一**して説明する（会話ターンだけ例外にしない）
- セッション中はモデル選択の行を disabled にする（`ChatRoomStore.isSessionActive` を見る）

### 5. API キーとの整合

プロバイダを変えるとキーが要る（Qwen → `dashscope-api-key`、OpenAI TTS → `openai-api-key`）。

- 選択肢の行に **キー未設定バッジ**を出す（`KeychainStore` を読むだけ。値は表示しない）
- 未設定でも選択自体は許す（`.secrets/` に置いて再インストールすれば入るため）。
  ただしセッション開始時の既存の失敗導線（`TurnBasedVoiceSession` の
  「DashScope API キーが未設定です」）に任せる

### 6. 料金画面の追従（既存のズレも直す）

- `AIPricing.estimatedCostUSD` は **record 時に provider / model から計算して保存**しているので、
  モデルを切り替えても過去の記録は正しいまま（設計として既に正しい）
- 一方 `AIPricing.currentRate(for:)`（`AIPricing.swift:167`）は「現在の既定モデル」を
  **ハードコード**している。ここを `ModelSettingsStore` の選択を引数に取る形へ変える
- **ついでに既存のズレを解消する**: `currentRate(for: .textToSpeech)` が
  `qwen3-tts-instruct-flash-realtime` を返したままで、2026-08-03 の Gemini 復帰
  （`SentenceTTSClientFactory.swift:16`・CLAUDE.md・ai-cost-map.md は更新済み）に追随していない。
  管理画面「料金」タブの TTS 行が、Gemini 単価で計上された金額の横に Qwen の単価を並べている。
  テスト `AIPricingTests.testCurrentRateMapsAllKindsToDefaultModels` も qwen 前提なので併せて更新
- `docs/specs/ai-cost-map.md` の「利用量の記録」節が「6 経路」と書いてあるが実際は 7 経路
  （翻訳を後から足した）。この作業のついでに直す

### 7. 診断ログ

セッション開始時に**全経路の実効モデルを 1 行**で `DiagnosticsLog` に残す
（現在は `TurnBasedVoiceSession.swift:485` の接続完了ログに STT / TTS / LLM の 3 つだけ出ている）。
モデル比較の実機検証で「どの構成の結果か」を後から追えるようにする。

## 管理画面の整理

### 現状

`AdminView`（sheet で提示）が `NavigationStack` + **segmented Picker で 5 タブ**を出し、
選択に応じて子ビューを差し替える。`-open-admin <タブ表示名>` で初期タブを指定できる
（`DebugLaunchArguments.swift:246`、`AdminView.Tab` の rawValue = 表示名がキー）。

### 変更案: ルートを List にして push する

segmented は 5 つで既に窮屈で、6 つ目は入らない。**ルートを標準の `List`（insetGrouped）にして
`NavigationLink` で子画面へ push する**形へ組み替える。iOS の設定画面と同じ構造で、
今後さらに増えても破綻しない。

| セクション | 行 | 遷移先 |
| --- | --- | --- |
| 記録 | 会話 / 記憶 | `SessionListView` / `MemoryAdminView` |
| コスト | 料金 / 容量 | `UsageDashboardView` / `StorageUsageView` |
| 設定 | **モデル**（新規） | `ModelSettingsView`（新規） |
| 開発 | 診断 | `DiagnosticsLogView` |

- 各行には**現在値のサマリを右側に出す**（料金 = 今月の推定額、容量 = 合計バイト、
  モデル = 会話ターンの選択、会話 = セッション数）。1 階層深くなるぶんをここで取り戻す
- **`-open-admin <タブ名>` の互換は維持する**。`AdminView.Tab` は残し、
  指定があればルート表示直後に対応する Destination を push する
  （`NavigationStack(path:)` にして初期 path を積む）
- DEBUG のセッション書き出しボタンは現在ツールバーにあるので、そのまま置く

### 退けた代替案

- **segmented のまま「その他」タブに畳む**: どの項目が「その他」かの基準が無く、増えるたびに再分類が要る
- **下タブ（TabView）**: sheet の中に下タブを置くのは iOS の作法から外れるし、5〜6 個だと文字が潰れる

### `ModelSettingsView`（新規）の構成

- 経路（`AIUsageEvent.Kind`）ごとに 1 セクション。各セクションに Picker（inline）+ 注記
- 注記に出すもの: 現在の単価（`AIPricing.currentRate` から生成）、キー未設定バッジ、
  「会話ターン + haiku-4-5 は system prompt のキャッシュが効かない」等のモデル固有の注意
- 「既定に戻す」ボタン（全経路をコード既定へ）
- フッタに「変更は次のセッション開始から反映されます」

## 影響範囲

**新規**
- `EslSpeakingCoach/Settings/ModelSettingsStore.swift`
- `EslSpeakingCoach/Usage/AIRouteModel.swift`
- `EslSpeakingCoach/Admin/ModelSettingsView.swift`

**変更**
- `Admin/AdminView.swift`（segmented → List + push、`NavigationStack(path:)`）
- `Support/DebugLaunchArguments.swift`（`-open-admin` の互換維持、必要なら経路別のモデル指定引数を追加）
- `Claude/TopicSuggestionClient.swift` / `MemoryUpdateClient.swift` / `TranslationClient.swift`
  （model / effort を Parameters 化）
- `Claude/ClaudeMessagesClient.swift`（effort を optional 化 = haiku 選択時に落とす）
- `Claude/SessionFeedbackClient.swift`（`static let model` → 注入）
- `Conversation/ChatRoomStore.swift`（構成の組み立て・ストア保持・セッション中フラグ）
- `Voice/TurnBasedVoiceSession.swift`（STT / TTS 構成の注入、開始ログに全経路のモデル）
- `Usage/AIPricing.swift`（`currentRate` を選択追従へ + TTS の Qwen 固定を解消）
- `Admin/UsageDashboardView.swift`（`currentRate` の呼び出し形が変わる）
- `Claude/CoachSystemPrompt.swift` / `QuizCoachSystemPrompt.swift`（キャッシュ最小プレフィックスの注記）
- `docs/specs/ai-cost-map.md`（7 経路への修正、切替可能になった旨）/ `CLAUDE.md`（切替手段の記述）

## テスト方針

**単体**
- `ModelSettingsStore`: 保存 → 復元 / 未設定はコード既定 / 未知 rawValue は既定へ正規化 /
  「既定に戻す」で保存値が消える
- `AIRouteModel`: 全 Kind に既定があり、既定は選択肢に含まれる（`AIPricingTests` の
  `testCurrentRateMapsAllKindsToDefaultModels` を選択追従版に置き換え）
- effort 分岐: haiku-4-5 を選ぶと `output_config.effort` がリクエストボディから消える /
  sonnet-5・opus-5 では従来どおり乗る（既存の `makeRequestBody` 系テストに倣って
  ボディの JSON を直接検証する）
- 各クライアントの `makeRequestBody` に選択モデルが乗る / usage の `model` も同じ値になる
- `AIPricing.currentRate`: 選択を変えると表示モデル・単価が追従する

**シミュレータ（`./run-simulator.sh`）**
- 管理画面の階層ナビゲーション、`-open-admin 料金` 等でその画面が直接開く（互換確認）
- モデルを変更 → `-start-conversation -send-text ...` でセッション開始 → 診断ログに選択モデルが出る
- 料金タブの種別内訳が選択に追従する
- キー未設定のプロバイダを選ぶとバッジが出る（`-delete-dashscope-key` と併用）

**実機（`./run-install-iphone.sh`）**
- TTS 切替（Gemini ⇄ Qwen）: 声質・レイテンシ・再読み上げ（キャッシュ音声と再生成音声の声の一致）
- STT 切替（gpt-live-transcribe ⇄ qwen3-asr）: マイクのサンプルレート切替（24kHz/16kHz）が
  正しく効くか、発話終端の挙動
- 会話ターンを opus-5 にしたときの max_tokens 1024 の妥当性（thinking で食われて切れないか）

## Phase 分割

- **Phase 1: 管理画面の情報設計** — ✅ **完了（2026-08-03）**
  segmented → List + push に組み替える（機能は現状維持）。`-open-admin` 互換維持、
  各行に現在値サマリ。ここだけで独立して完結する
  - ルートは 記録（会話 / 記憶）/ コスト（料金 / 容量）/ 開発（診断）の 3 セクション。
    各行に現在値（25 件 / 更新日 / 今月 $0.277 / 4.30 MB / ログ最終更新）を右肩に出す。
    容量だけディレクトリ走査なのでバックグラウンド計測（表示は「計測中…」）
  - `-open-admin <表示名>` はその画面まで push した状態で開く。**引数なし / 不明名はルート**
    （旧: 会話タブ固定）。`AdminView.Tab` の rawValue = 指定キーなので据え置き
  - 子画面にも「閉じる」を出す（push 先からシートを直接閉じられる）
  - 単体テスト 2 件追加（全 Tab がセクションにちょうど 1 回 / rawValue の据え置き）。
    378 + 12 テストパス。シミュレータで ルート / 料金 / 診断 / 会話 / 不明名の表示を確認済み
- **Phase 2: Claude 系 5 経路のモデル選択** — ✅ **完了（2026-08-03）**
  `ModelSettingsStore` / `AIRouteModel` / `ModelSettingsView` を追加し、
  会話ターン・トピック・フィードバック・記憶・翻訳を切替可能にする。effort 分岐込み
  - 選択肢と既定は `Claude/ClaudeModel.swift` の `ClaudeModel` / `ClaudeRoute` に集約
    （**プランでは `Usage/AIRouteModel.swift` としていたが `Claude/` へ置いた**。
    使うのは Claude/ 配下の 5 クライアントで、Usage/ は課金記録の担当だから）
  - **effort の出し入れは `ClaudeModel.supportsEffort` の 1 箇所**。dict 組み立ての 4 クライアントは
    `ClaudeRequestBody.outputConfig(model:effort:schema:)` を通す（haiku-4-5 では effort だけ落ちて
    structured outputs は残る）。会話ターンは `output_config` ごと落とす
  - **opus-5 の会話ターンは max_tokens 4096**（thinking と本文で予算を共有するため 1024 だと切れうる。
    `ClaudeModel.turnMaxTokens`。暫定値なので実機で詰める）
  - 管理画面は「モデル」項目を 設定 セクションに追加。経路ごとに 単価（`AIPricing` から取得）/
    effort / キャッシュ警告 / 既定との差 を出す。**キャッシュ警告は言うことがあるときだけ出す**
  - 単体テスト 15 件追加（保存・フォールバック・既定は保存しない・reset / 5 経路のボディと usage /
    effort の出し入れ）。393 + 12 テストパス
  - シミュレータ: モデル画面の既定表示と変更後表示、ルートの「2 経路変更」、
    **haiku-4-5 を選んだセッションのログが `LLM: claude-haiku-4-5` になること**を確認
    （`-open-admin モデル` / セッションログ）。実 API 呼び出しでの疎通は実機で確認する
- **Phase 3: TTS / STT の選択** — ✅ **完了（2026-08-03）**
  プロバイダ・モデル選択、キー未設定バッジ、セッション中は変更不可の扱い、
  起動引数との優先順位の整理
  - 既定は `TTSProvider.default`（gemini）/ `STTModel.default`（gpt-live-transcribe）へ寄せた。
    `SentenceTTSClientFactory.Configuration` と `OpenAITranscriptionConfiguration` の既定値も
    ここを見るので、**既定の単一の正はコード側のまま**
  - 新規 `STTModel`（3 択）。rawValue がそのまま `transcription.model` に入り、
    **VAD の方式・接続クライアント・マイクのサンプルレートがそこから派生する**
  - **優先順位は DEBUG 起動引数 > 管理画面の選択 > コード既定**。
    `currentTTSConfiguration()` は static → インスタンスメソッドにして選択を土台にした
  - **セッション中の変更は禁止にせず「次のセッションから」に統一**した（TTS / STT は
    セッション開始時に構成へ焼き込まれるので、走っているセッションは影響を受けない）。
    ただし**再読み上げの `UtteranceReplayer` は使い回すと古いプロバイダの声のままになる**ため、
    プロバイダが変わったら作り直す
  - キー未設定バッジは Keychain の**有無だけ**見る（値は読まない・表示しない）
  - 単体テスト 8 件追加（音声 2 経路の保存・フォールバック・reset / STT 選択 → VAD・サンプルレート /
    プロバイダ → クライアントと usage 種別 / 単価表示）。401 + 12 テストパス
  - シミュレータ: モデル画面に TTS セクションが出ること、
    **Qwen TTS + gpt-4o-transcribe を選んだセッションのログが
    `接続完了（STT: gpt-4o-transcribe, TTS: qwen3-tts-instruct-flash-realtime, …）` になること**を確認。
    画面下部（STT セクションと「すべて既定に戻す」）は**スクロールできず未確認**
    （シミュレータへタップ・スクロールを送れないため。実機で確認する）
- **Phase 4: 料金画面の追従と仕上げ** — ✅ **実装完了（2026-08-03）／実機確認だけ残**
  `AIPricing.currentRate` を選択追従へ（TTS = Qwen 固定のズレ修正を含む）、
  診断ログに全経路のモデルを出す、ドキュメント更新、実機確認
  - `ModelSelectionSnapshot`（選択を 1 回読み出した値型）を新設し、
    `currentRate(for:selection:at:)` と診断ログの両方がこれを使う
    （描画のたびに UserDefaults を引かない・1 画面内で表示がぶれない）
  - **TTS 行が Qwen 固定だったズレはこれで解消**（既定なら gemini-3.1-flash-tts-preview を出す）。
    導入価格の補足も「選んだモデルに導入価格があるときだけ」出るようになった（opus-5 では出ない）
  - セッション開始時に `model: turn=… topic=… feedback=… memory=… translation=… tts=… stt=…` を
    診断ログへ 1 行。モデル比較の実機検証で「どの構成の結果か」を後から辿れる
  - 単体テスト 2 件追加（選択追従 / 診断ログ 1 行に全 7 経路）+ 既存 2 件を選択渡しへ更新。
    403 + 12 テストパス
  - シミュレータ: 料金タブが既定で Gemini を出すこと、opus-5 + Qwen を選ぶと
    `claude-opus-5・入力 $5 / 出力 $25` と `qwen3-tts-instruct-flash-realtime` に追従すること、
    セッション開始時の診断ログ 1 行を確認
  - **残: 実機確認**（モデルを切り替えて 1 セッション。haiku で effort を落とせているか =
    400 にならないか、opus-5 の max_tokens 4096 が妥当か、Qwen TTS / gpt-4o-transcribe の音声。
    加えてモデル画面下部の表示）
