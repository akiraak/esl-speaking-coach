# クイズを独立モードから単語モード内の導線に変える

## 目的・背景

単語クイズは現在ヘッダのピルに並ぶ**第 3 の練習モード**（`PracticeMode.quiz`）だが、
クイズは「単語練習の一部（練習した語の復習）」であり、雑談（会話）と練習（単語）という
モード切替の粒度とは合っていない。ヘッダからクイズを外して 2 択（会話 / 単語）に戻し、
**単語カードの中に、練習の導線（単語を入力 / 単語帳から選ぶ / 未練習からランダムに選ぶ）と
同じレベルでクイズの開始ボタンを置く**。

- クイズセッションそのものの挙動（`[Quiz words: X]`・専用 system prompt・`[end]` 自動終了・
  区切り「クイズ」・フィードバック見出し「単語クイズ」・管理画面 🎯・出題済み除外）は**変えない**
- 変えるのは「どこから始めるか」だけ: クイズ専用カードを廃止し、単語カードに統合する

## 決定サマリ

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| `PracticeMode.quiz` の扱い | **enum のケースとしては残す**（セッションの mode・保存・プロンプト選択・文言の切替に使い続ける）。ヘッダのピルの選択肢からだけ外す | `ChatSessionRecord.modeRawValue` に `quiz` が保存済みで、`PracticeMode(storedValue:)` は SwiftData の復元にも使われている。ケースを消すと既存レコードが conversation に化ける |
| ピルの選択肢 | `PracticeMode.selectableModes = [.conversation, .word]` を追加し、ピルは `allCases` ではなくこれを回す | UI に出すモードとセッションの mode を分離する最小手 |
| UI モードの復元 | `ChatRoomStore.init` / DEBUG 上書きの直後に **quiz → word へ正規化**する（純関数にしてテスト）。`PracticeMode(storedValue:)` 自体は変えない | UserDefaults に `quiz` が残った端末（今のバージョンで保存済み）はクイズが単語モード配下になった以上、単語モードで起動するのが自然。`init(storedValue:)` を変えると保存済みセッションの復元まで壊れる |
| セッション mode の分離 | `startSession(topic:fromCard:)` に `mode` 引数を追加（既定 = `practiceMode`）。`startQuizSession` は `mode: .quiz` で呼ぶ。以降のセッション処理（`activeSessionMode`・`beginSession`・`launchSession` の configuration・`rebuildHistory`・記憶ノート判定・区切り）は **`practiceMode` ではなく渡された mode / `activeSessionMode`** を使う | クイズ中は UI モード = word・セッション = quiz と食い違う。現在は両者が常に一致している前提で `practiceMode` を直接読んでいる箇所（特にエラー再開の `rebuildHistory` — 今のままだと `[New word:]` で再開してしまう）を直す必要がある |
| セッション中の文言 | `ChatRoomStore` に `sessionWordingMode`（セッション中・再開待ちは `activeSessionMode`、それ以外は `practiceMode`）を公開し、終了ボタン / 確認アラートはこれを使う | クイズ中の終了ボタンを「このクイズを終了」のままにする（practiceMode を渡すと「この単語を終了」になってしまう） |
| クイズ専用カード | **廃止**。`postTopicCard` の quiz 分岐と `TopicCardView.quizBody` を削除し、単語カードに統合。`TopicCard.quizPoolCount` は単語カードで設定する | カードが 1 種類減り、モード切替でクイズカード ⇄ 単語カードを差し替える必要も消える |
| 単語カードのクイズ導線 | 既存 3 ボタンと同列の 4 つ目として、「未練習からランダムに選ぶ」の下に **「練習済みからクイズ（1語）」**（`questionmark.circle`）を置く。練習済み 0 語は無効化（案内文は出さない ―― カードには既にピル・集計があり、0 語なら「前に練習した単語」も無いので状況は伝わる） | 「練習と同じレベルに表示」の最直訳。caption 行を足すよりボタン 1 個が単語カードの密度に合う |
| クイズ開始時のカード表示 | クイズ開始では使用済みカードに `selectedTitle` を**設定しない**（グレーアウトのみ） | 単語カードの `selectedTitle` は選んだ語のピル表示に使われるため、設定すると出題語がチャット欄に見えてしまう（docs/plans/archive/quiz-one-word.md の方針を維持） |
| DEBUG 起動引数 | `-start-quiz` は**単語カードの**クイズボタンをタップした扱いに変更（`-practice-mode word` と併用）。`-practice-mode quiz` は正規化で word になる | E2E の導線を実 UI に合わせる |
| 使わなくなる quiz の UI プロパティ | `displayName` / `symbolName` / `topicCardTitle` / `idlePrompt` の quiz ケースは到達しなくなるが**残す**（switch の網羅性を保つ。コメントだけ現状に合わせる）。`endSessionButtonTitle` / `sessionListMarker` / `feedbackTopicLabel` 等は引き続き使う | ケース削除はできない以上、プロパティだけ虫食いにする利点が無い |

## 対応方針

### Phase 1: UI モードとセッション mode の分離

- `PracticeMode.selectableModes` を追加し、`ChatRoomView.modePill` の `ForEach` を差し替える
- UI モードの復元を純関数化: `ChatRoomStore.restoredPracticeMode(storedValue:)`
  （quiz → word、未知・nil → conversation）。init と DEBUG 上書きの両方をこれに通す
- `startSession(topic:fromCard:mode:)`（既定 = `practiceMode`）にし、セッション処理を渡された
  mode / `activeSessionMode` 基準へ:
  - 区切り `dividerLabel` / `beginSession(mode:)` / `usesMemoryNote` / `activeSessionMode` ← 引数 mode
  - `launchSession` の `configuration.practiceMode` / `rebuildHistory`（学習者ファースト判定・
    `SessionOpeningMessage.compose(mode:)`）← `activeSessionMode`
  - 候補持ち越し・`recentTopicTitles` は従来どおり conversation のみ（挙動不変）
- `sessionWordingMode` を公開し、`ChatRoomView` の終了確認アラートと `TimelineBottomBar` に渡す

### Phase 2: 単語カードへクイズ導線を統合

- `postTopicCard` の word 分岐で `quizPoolCount` も設定し、**quiz 分岐を削除**
  （switch は `case .word, .quiz:` で word カードを出す。正規化により実際には到達しない）
- `TopicCardView.wordBody` に 4 つ目のボタン「練習済みからクイズ（1語）」を追加
  （`onStartQuiz` / `card.quizPoolCount == 0 || card.isUsed || isRandomWordLoading` で無効化）。
  `quizBody` と body の quiz 分岐を削除
- `startQuizSession(fromCard:)` の guard を `practiceMode == .word` に変更し、
  `startSession(..., mode: .quiz)` で開始。クイズ開始ではカードの `selectedTitle` を設定しない
- `cardReplacement` は 2 モード（クイズカードが無くなるので現行テストの quiz ケースを削除）
- `DebugLaunchArguments` のコメント更新（`-start-quiz` は word モードで発火）と
  `postTopicCard` word 分岐への発火移設

### Phase 3: 検証

- 単体テスト:
  - `PracticeModeTests`: `selectableModes = [.conversation, .word]`。既存の quiz プロパティのテストは維持
  - 新規 or `PracticeModeTests`: `restoredPracticeMode`（quiz → word / word → word / 未知 → conversation）。
    `PracticeMode(storedValue: "quiz")` が **.quiz のまま**であること（保存済みセッションの復元を壊さない）
  - `PracticeModeCardTests`: クイズカードの差し替えテストを削除
  - `sessionWordingMode`（セッション中 = activeSessionMode / 終了後 = practiceMode）
- `xcodebuild` でビルド + 全テストパス
- シミュレータ E2E:
  1. ピルの選択肢が会話 / 単語の 2 択
  2. 単語カードに「練習済みからクイズ（1語）」が出て、練習済み 0 語で無効
  3. `-practice-mode word -start-quiz` でクイズ開始 → ヘッダは「単語」のまま・
     終了ボタンが「このクイズを終了」・区切り「クイズ」・使用済みカードに出題語が出ない
  4. 自動終了 → フィードバック見出し「単語クイズ」→ 次の単語カード（クイズボタン付き）
  5. mode=quiz 保存・管理画面 🎯・出題済み除外（2 回目で別の語）の維持
  6. クイズセッション中のエラー再開が `[Quiz words:]` で再開する（可能なら。難しければ
     `rebuildHistory` 相当の単体テストで代替）
  7. UserDefaults に `quiz` が残った状態からの起動で単語モードになる（`-practice-mode quiz` で確認）
  8. 会話・単語モードの退行なし
- 実機確認はユーザーが実施

## 影響範囲

- 変更: `PracticeMode.swift`（`selectableModes`・コメント）/ `ChatRoomStore.swift`
  （復元正規化・`startSession(mode:)`・`sessionWordingMode`・`postTopicCard`・
  `startQuizSession`・`cardReplacement` 周りのテスト対象）/ `ChatRoomComponents.swift`
  （`wordBody` にクイズボタン・`quizBody` 削除）/ `ChatRoomView.swift`（ピル・文言の参照先）/
  `DebugLaunchArguments.swift`（コメント）+ テスト
- 触らない: `QuizCoachSystemPrompt` / `SessionOpeningMessage` / `ChatHistoryStore`
  （`quizzedTitlesAll` 等）/ 出題選択の純関数（`quizPool` / `quizWords` ほか）/
  音声レイヤ / `SessionListView`（🎯 は `mode` 基準のまま）/ フィードバック生成
- 保存データ: 変更なし（`modeRawValue` の `quiz` はそのまま読める。UserDefaults の
  `chatRoomPracticeMode` = `quiz` だけ起動時に word へ正規化）

## 未決事項

- クイズボタンの文言は「練習済みからクイズ（1語）」を仮とする（実機で見て調整。
  出題数を変えたときに文言が古くならないよう `quizWordCount` から組み立てる）
- 単語カードが縦に伸びる（ボタン 4 つ + ピル + 集計）。気になったらボタンの 2 列化等は別タスク

## 関連タスク

- このプランは既存構造を保ったままの最小変更で行う（`selectableModes` と `sessionWordingMode`
  で UI モードとセッション mode の不一致を吸収する）。1 つの `PracticeMode` が UI モード・
  セッション種別・保存タグ等の多役を兼ねている構造自体の整理は、**別タスク**
  「`PracticeMode` 周りを現状の機能が最もシンプルに表現される構造へリファクタリングする」
  （TODO.md）で行う
