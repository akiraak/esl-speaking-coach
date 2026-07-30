# 単語帳ピッカーに単語の詳細画面を追加 — 実装プラン

## 目的・背景

単語帳ピッカー（`docs/plans/archive/wordbook-word-picker.md`・2026-07-29 完了）は一覧に
英語 + 第 1 義 + CEFR + 品詞しか出しておらず、**その語を今日練習するか決める材料が薄い**
（複数の語義・例文・使い方ノートは見えない）。esl-learning-assistant には語ごとの生成済み
単語情報（`wordInfo`）が丸ごと保存されており、読み取り専用 API で取得できるので、
ピッカーから 1 語の詳細画面を開けるようにする。

既存 TODO「単語会話用の辞書機能」（会話中の辞書引き）とは別タスク。ただし本タスクで作る
詳細 API クライアントとモデルはそちらでも再利用できる。

## API 調査結果（2026-07-29 実施・本番実データで確認済み）

`../esl-learning-assistant/backend/src/wordsApi.ts:120-143`（`buildWordDetail`）と
`wordInfo.ts:132-152`（`WordInfo` / `WordSense`）。

- **エンドポイント**: `GET https://esl.chobi.me/api/words/:word?targetLanguage=ja`
  - 認証は一覧と同じ `X-API-Secret`。AI は呼ばれない（課金なし）
  - `:word` は正規化キー（trim + 小文字）で引く。**熟語は URL エンコード**（`even%20though`）
  - 見つからない語は 404 `{"error":"word not found"}`、`word_info_json` が壊れた行は 500
- **レスポンス**: `{ word, targetLanguage, wordInfo, model, createdAt, updatedAt, generationCount }`
- **`wordInfo` の全項目**（500 相当以外は必ずキーが存在。null / 空配列があり得る）:

| 項目 | 型 | 内容（本番実例: disability / even though で確認） |
| --- | --- | --- |
| `senses` | 配列 | 語義（複数）。各要素 `meaning`（母語） / `englishDefinition` / `partOfSpeech` / `note`（null あり） |
| `pronunciation` | object | `ipa`（熟語は全体を 1 組のスラッシュ）/ `syllables`（`dis-uh-BIL-uh-tee`。熟語は null） |
| `inflections` | 配列 | 活用形。`{form, text}`（例: plural / disabilities）。固定イディオムは空配列 |
| `examples` | 配列 | 例文。`{english, translation}`（実データは 3 件程度） |
| `collocations` | [String] | よく使う組み合わせ |
| `synonyms` / `antonyms` | [String] | 類義語 / 反意語（空配列あり） |
| `usageNote` | String? | 使い方ノート（母語） |
| `cefrLevel` | String? | A1〜C1（null あり） |
| `etymology` | String? | 語源 |
| `register` | String? | 使用域（「フォーマル」等。null あり） |
| `commonMistakes` | String? | よくある間違い |

- ルート外のメタ: `model`（生成モデル）と `generationCount` は学習に不要なので**表示しない**

## 決定サマリ

| 項目 | 決定 |
| --- | --- |
| 導線 | ピッカーの各行に **ⓘ（info）ボタン**を追加 → 詳細画面へ push。**行本体タップ = 即セッション開始は変えない**（既存の流儀を壊さない） |
| 画面の形 | ピッカーの `NavigationStack` 内に push（シートの上にシートを重ねない） |
| 詳細からの開始 | 画面下部に「この単語を練習する」ボタン → シートを閉じて既存の `onSelect(word)` 経路で `startSession` |
| 表示内容 | `wordInfo` 全項目（語義 / 発音 / 活用 / 例文 / コロケーション / 類義・反意 / ノート / 語源 / 使用域 / 間違い）。null・空配列のセクションは出さない |
| 取得タイミング | 詳細画面を開くたびに取得（一覧と同じ流儀。キャッシュしない）。ローディング / エラー + 再試行は画面内で完結 |
| モデル | `WordBookWordDetail`（自前モデル。API レスポンス型を UI に流さない。一覧の `WordBookEntry` はそのまま） |

## 対応方針

### Phase 1: WordBookClient の詳細 API 対応

1. `WordBookClient` に `fetchWordDetail(secret:word:) async throws -> WordBookWordDetail` を追加
   - `makeDetailRequest(secret:word:)`: パスコンポーネントの percent-encode（熟語のスペース）+
     `targetLanguage=ja`。`appending(path:)` のエンコード挙動をテストで固定する
   - `parseDetailResponse(_:)`: `wordInfo` を `WordBookWordDetail` へ詰め替え。null / 空配列は
     そのまま保持（表示側で畳む）。壊れた JSON は `decodingFailed`
   - 404 は専用ケース `WordBookError.wordNotFound`（「単語帳に詳細がありません」）にする。
     一覧に出た直後に消えるのは稀だが、メッセージを 401 や 500 と混ぜない
2. `WordBookWordDetail` と入れ子の値型（`Sense` / `Pronunciation` / `Inflection` / `Example`）を
   `WordBookClient.swift` 内に追加（一覧モデルと同居。ファイル分割は肥大してから）

### Phase 2: 詳細画面とピッカーからの導線

1. `WordBook/WordBookDetailStore.swift`（新規、`@MainActor @Observable`）
   - 状態: `loading / loaded(WordBookWordDetail) / failed(message)` + `retry()`。
     ピッカー store と同じく fetch closure を init 注入してフェイクで単体テスト
2. `WordBook/WordBookDetailView.swift`（新規）
   - 見出し: 語 + CEFR バッジ + 使用域、IPA + syllables
   - セクション: 語義（番号付き。meaning / englishDefinition / partOfSpeech / note）→ 例文
     （英語 + 訳）→ 活用形 → コロケーション / 類義語 / 反意語（チップ折り返し）→
     使い方ノート → よくある間違い → 語源。**null / 空のセクションは丸ごと非表示**
   - 下部固定の「この単語を練習する」ボタン（`ChatTheme.accent`）→ `dismiss` 後に
     `onSelect(word)`（ピッカー行タップと同じ closure を渡す）
3. `WordBookPickerView` の行に ⓘ ボタンを追加し、`navigationDestination(item:)` で push。
   行本体のタップ判定と干渉しないよう ⓘ は `Button` を分ける（`List` の行内複数ボタンは
   `.buttonStyle(.borderless)` で個別タップにする）
4. E2E 用の DEBUG 起動引数 `-wordbook-detail <word>` を追加（ピッカー表示後にその語の詳細を
   自動 push。スクリーンショット確認用）

### Phase 3: 検証・ドキュメント・後片付け

1. `xcodegen generate` → ビルド + 全テストがグリーン
2. シミュレータ E2E: `-practice-mode word -open-wordbook -wordbook-detail disability` で
   本番 API の詳細表示、熟語（`even though`）のエンコード、404（存在しない語）、
   「この単語を練習する」→ セッション開始（`-pick` 系の自動化 or 手動）を確認
3. 実機確認（ユーザー）: ⓘ の押しやすさ・長文セクションのスクロール・詳細からの練習開始
4. `docs/specs/word-practice.md` の単語帳節に詳細画面を追記
5. TODO → DONE、本プランを `docs/plans/archive/` へ

## 影響範囲

- 新規: `EslSpeakingCoach/WordBook/WordBookDetailView.swift` / `WordBookDetailStore.swift`、
  `EslSpeakingCoachTests/WordBookDetailStoreTests.swift`
- 変更: `EslSpeakingCoach/WordBook/WordBookClient.swift`（詳細 API + モデル追加）、
  `WordBookPickerView.swift`（ⓘ + navigationDestination）、
  `Support/DebugLaunchArguments.swift`（`-wordbook-detail`）、
  `EslSpeakingCoachTests/WordBookClientTests.swift`（詳細ぶんを追記）、
  `docs/specs/word-practice.md`
- 触らないもの: セッション開始以降の全経路、`ChatRoomView` / `ChatRoomStore`（`onSelect` closure を
  そのまま流用）、一覧の取得・検索・ページング、esl-learning-assistant 側（API は稼働済み）

## テスト方針

- 単体テスト:
  - client: `makeDetailRequest`（パスエンコード・熟語・ヘッダ・targetLanguage）/
    `parseDetailResponse`（フル JSON・null 項目・空配列・壊れた JSON・404 → `wordNotFound`）
  - store: フェイク fetch で 成功 / 失敗 → 再試行 / 404 メッセージ
- 表示の実挙動（長文の折り返し・チップの折り返し・セクションの出し分け）はシミュレータで
  本番実データ（disability = 全項目あり / even though = syllables・register null・antonyms 空）を
  使って目視確認

## スコープ外（今回はやらない）

- 会話中の辞書引き（既存 TODO「単語会話用の辞書機能」。本タスクの client / モデルを再利用予定）
- 詳細のローカルキャッシュ・オフライン対応
- TTS での発音再生（wordInfo に音声は無い。やるなら別タスク）
- 練習履歴との突き合わせ表示（練習済みマーク等）
