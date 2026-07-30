# 練習済み単語から単語クイズを受けられるクイズモードを追加する

TODO: 「練習済み単語から単語クイズを受けれる会話モードを追加する」

## 目的・背景

単語モードで練習した語は単語カードのピルから**再練習**できるが、それは「もう一度教わる」導線で、
**覚えているかを試す**導線が無い。語彙は思い出す練習（retrieval）で定着するので、
練習済みの語からランダムに出題される**単語クイズ**を受けられる第 3 の練習モードを追加する。

- 出題の母集団は**このアプリの単語モードで練習した語**（`ChatSessionRecord` mode=word の `topicTitle`）
- Chobi が出題者、学習者が英語で答える。会話は従来どおり**英語のみ**・音声ターン制
- 発話量を稼ぐ第一目的は変えない: 正解を言って終わりではなく、答えた語を自分の文で使うところまで回す

## 決定サマリ

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| モードの持ち方 | `PracticeMode` に第 3 のケース **`quiz`** を追加（ヘッダのピルに「クイズ」が並ぶ） | 既存の word 追加と同じ形。rawValue `quiz` は未知値として旧バージョンでも conversation にフォールバックする（`init(storedValue:)` は変更不要） |
| 出題ソース | 練習済みの語（`ChatHistoryStore` の mode=word セッションの `topicTitle`）を正規化キーで畳み、**ランダムに最大 5 語**選ぶ | TODO の要件どおり。単語帳・未練習語は使わない（まだ知らない語のクイズは成立しない）。重複は新しい表記を残す（ピルと同じ流儀） |
| 1 セッションの構成 | 選んだ**最大 5 語（`quizWordCount`）を 1 セッションで順に出題**。全語出し終えても終わらず、角度を変えて再出題を続ける | 単語モードの「1 語をじっくり」とは役割が違う（教える vs 思い出させる）。5 語で 1 周 10 分程度を想定し、続けたければ回し続けられる |
| 語の渡し方 | セッション開始時に `[Quiz words: put off, resilient, ...]` を 1 行送る（`openingControlKey` = `Quiz words`）。`topicTitle` にも同じ連結文字列を保存 | 既存の `startSession(topic:)` の topic を連結文字列にするだけで、区切り・保存・フィードバック・エラー再開の全経路がそのまま通る。途中で語を追加注入する仕組みは作らない |
| クイズの進め方（prompt 骨子） | Chobi が 1 ターン 1 問: 意味や場面を英語で説明して**語を思い出させる** / 穴埋め / 自分の文で使わせる、を織り交ぜる。正誤の確認は短く、答えられたら**その語で自分の文**を作らせてから次へ。分からなければヒント（頭文字・場面）を出し、答えは最後まで教えずに粘らせすぎない | 思い出す練習が主目的。ただし詰問にならないよう、single most important goal（学習者の発話量）は word プロンプトから引き継ぐ |
| キャラの役割 | Chobi = 出題者（先生）/ Naruko = **一緒にクイズを受ける生徒**。たまに先に答えて間違え、Chobi に直される（学習者への圧を下げる）。学習者を訂正しない | 既存 2 キャラの関係を保つ。単語モードの役割分担の自然な延長 |
| 記憶ノート | **注入も更新もしない**（`usesMemoryNote` = false） | 単語モードと同じ理由（1 語練習に効かず、逐語がノートに入ると雑談品質が落ちる） |
| 終わり方 | **終了ボタンのみ**（`endsOnGoodbye` = false）。プロンプトも自分から終わらせない | 単語モードと同じ。全語出し終えたら難度や角度を変えて続ける |
| フィードバック | 既存 `SessionFeedbackClient` を流用、1 行目だけ `Quiz words: <連結>`（`feedbackTopicLabel`） | word 追加時と同じ手筋。system prompt は 1 文字も変えない（キャッシュ維持） |
| カード | 見出し「🎯 単語クイズ」+ 母集団の説明（`練習済み N語からランダムに5語を出題`）+ 「クイズを始める」ボタンの 1 枚。練習済み 0 語ならボタン無効 + 「先に単語モードで練習してください」 | 候補生成・入力・単語帳ボタンは載せない（出題は全部アプリ任せ、が このモードの価値）。出題語はカードに**出さない**（始まる前に見えたらクイズにならない） |
| クイズは「練習済み」を増やさない | mode=quiz セッションは `recentWords` / `practicedWordsAll` / 単語カードの集計の**母集団に入れない**（既存フィルタが mode=word のままなので何もしなくてよい） | クイズは復習であり新規練習ではない。単語カードのピル・未練習の定義を汚さない |
| system prompt | 新規 `QuizCoachSystemPrompt.swift`（固定文・`cache_control` 付き）。出力形式・音声・言語ルール節は word プロンプトから流用し、進行節だけ差し替える | キャッシュ最小プレフィックス 1024 トークン（sonnet-5）を満たす長さにする（word 版は 2,330 トークンなので同構成なら満たす） |

## 対応方針

### Phase 1: `PracticeMode.quiz` とモード分岐の土台

- `PracticeMode` に `case quiz` を追加し、全プロパティを埋める:
  `displayName` = クイズ / `symbolName` = `questionmark.circle` / `openingControlKey` = `Quiz words` /
  `systemPrompt` = `QuizCoachSystemPrompt.text` / `usesMemoryNote` = false /
  `feedbackTopicLabel` = `Quiz words` / `endsOnGoodbye` = false
- switch の網羅性エラーを頼りに文言分岐を埋める（`if mode == .word` の三項演算子が
  3 モードで破綻する箇所は `PracticeMode` のプロパティへ寄せる。spec の方針どおり）:
  - セッション区切り `dividerLabel` → `クイズ: <連結>`
  - 終了ボタン / 確認アラート → 「このクイズを終了（しますか？）」
  - 未開始時の入力バー → 「カードからクイズを始めてスタート」
  - 管理画面のセッション一覧 → `🎯 <連結>`（word の `📖` と同じ手筋）
  - 単語入力アラート（`isWordMode` 分岐）はクイズカードに入力ボタンが無く到達しないので現状のまま
- `cardReplacement`（モード切替のカード差し替え）: クイズカードは候補を持たないので
  word と同じ扱いになることをテストで固定

### Phase 2: クイズカードと出題選択

- 出題の純関数を `ChatRoomStore` に追加:
  - `quizPool(from recentWords: [String]) -> [String]`: 正規化キー（`normalizedWordKey`）で畳んで
    新しい表記を残した練習済み語（実体は `practicedWordSuggestions` の上限なし版。定義を共有する）
  - `quizWords(pool: [String], count: Int, using rng:) -> [String]`: ランダムに `count` 語
    （`quizWordCount` = 5。pool がそれ未満なら全語）。RNG 注入でテスト可能に（`randomWordChoice` と同じ流儀）
- `TopicCard` に `quizPoolCount: Int` を追加（カード投稿時に確定。`wordSuggestions` と同じ扱い）
- `postTopicCard()` を practiceMode の switch にし、quiz カード（`TopicCard(mode: .quiz)` +
  `quizPoolCount`）を投稿する
- `TopicCardView` に `quizBody` を追加: 母集団の説明 caption + 「クイズを始める」ボタン
  （`quizPoolCount == 0` は無効化 + 案内文言）。使用済みカードには出題した語（`selectedTitle` =
  連結文字列）を残す（word カードと同じ見た目の流儀）
- `ChatRoomStore.startQuizSession(fromCard:)` を追加: `recentWords` → `quizPool` → `quizWords` →
  連結して既存 `startSession(topic:fromCard:)` を呼ぶ（ネットワーク不要・全部ローカル）。
  診断ログに `quiz: 母集団N語 → <選んだ語>` を 1 行残す
- DEBUG 起動引数 `-start-quiz`（クイズカードの開始ボタンをタップした扱い。E2E 用）を追加。
  `-practice-mode quiz` は rawValue 経由で自動対応

### Phase 3: クイズ用 system prompt

- `QuizCoachSystemPrompt.swift` を新規作成。構成は `WordCoachSystemPrompt` と同じ骨格
  （Characters / The quiz words / How the quiz runs / Correcting / Output format / Language rules /
  Speech interface / App control messages / Session flow）で、進行節をクイズ用に書く:
  1. `[Quiz words: ...]` の語を 1 ターン 1 問で順に出題（順番はシャッフル済みなのでそのまま）
  2. 問い方を織り交ぜる: 意味・場面の英語説明から語を思い出させる / 穴埋め / その語で自分の文を作らせる
  3. 答えられたら短く確認し、**自分の文で使わせてから**次の語へ。間違い・度忘れはヒント → 正解を
     短く教えて使わせて次へ（引っ張らない）
  4. 全語終わっても終了せず、答えにくかった語を別の角度で再出題し続ける。自分から終わらせない
- 出力形式（`Chobi: ` / `Naruko: ` タグ・1 ターン 1 質問・英語のみ・STT 誤認識の扱い）は
  word プロンプトの文面を踏襲する
- トークン数を数え、1024 未満なら例示を足して満たす（実装時に確認してプランに追記）

### Phase 4: 検証

- 単体テスト:
  - `PracticeModeTests`: quiz の全プロパティ（既存の word のテストに並べる）
  - 新規 `QuizWordsTests`（`RandomWordChoiceTests` の流儀）: 畳み込み（新しい表記が残る）/
    seeded RNG で選択固定 / pool < count で全語 / pool 空で空配列
  - `SessionOpeningMessageTests`: quiz は `[Quiz words: ...]` の 1 行だけ（Memory を混ぜない）
  - `PracticeModeCardTests`: quiz への / からの切替（会話カードの持ち越しが生きること）
  - `ChatRoomStore.dividerLabel` / 管理画面の見出しの quiz ケース
- `xcodebuild` でビルド + 全テストパス
- シミュレータ E2E: `-practice-mode quiz -start-quiz -send-text ... -end-session` で
  (1) カードに母集団の語数が出て開始できる (2) `[Quiz words: ...]` で始まり出題される
  (3) goodbye で終わらない (4) ボタン終了 → `Quiz words:` ラベルでフィードバック
  (5) 区切り `クイズ:` / 管理画面 `🎯` / mode=quiz で保存
  (6) 練習済み 0 語（初期化した端末）でボタン無効
  (7) 会話・単語モードの退行が無い（単語カードのピル・集計にクイズセッションが混ざらない）
- 実機確認はユーザーが実施（音声での出題・回答の体感、5 語の長さの妥当性）

## 影響範囲

- 変更: `PracticeMode.swift` / `ChatRoomStore.swift`（カード投稿・純関数・`startQuizSession`・
  `dividerLabel`）/ `ChatRoomView.swift`（文言分岐・`-start-quiz`）/ `ChatRoomComponents.swift`
  （`quizBody`・終了文言）/ `SessionListView.swift`（見出し）/ `DebugLaunchArguments.swift` + テスト
- 追加: `Claude/QuizCoachSystemPrompt.swift`
- 触らない: 音声レイヤ（`VoiceSession` / STT / TTS）・`ScriptStreamChunker`・翻訳・料金記録・
  `SessionFeedbackClient` の system prompt・`ChatHistoryStore` のフィルタ（mode=word のまま）・
  単語帳連携（`WordBook/`）・記憶ノート
- 保存: `ChatSessionRecord.modeRawValue` に `quiz` が入るだけ（String なのでマイグレーション不要。
  旧バージョンで開いた場合も `init(storedValue:)` が conversation に落とすだけで壊れない）

## 未決事項

- 出題数 5（`quizWordCount`）の妥当性は実機で体感して調整する（定数 1 箇所）
- 問い方のバリエーション・ヒントの出し方の細部はプロンプト実装時に詰め、E2E の会話を見て調整する
- 正誤の記録・語ごとの成績は**残さない**（履歴とフィードバックで足りる。SRS 的な優先度付けと合わせて
  引き続きスコープ外。欲しくなったら別タスク）
- クイズ専用フィードバックプロンプト（まずは流用。単語モードと同じ判断）
- 出題を「最近練習した語を優先」等に重み付けするか（まずは一様ランダム）
