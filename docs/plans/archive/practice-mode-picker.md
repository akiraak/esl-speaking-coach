# 練習モードの切替をメニュー選択にする — 実装プラン

## 目的・背景

ヘッダの練習モードピル（📊 の左）は現在**タップで会話 ⇄ 単語をトグル**する
（`docs/plans/word-practice-mode.md` Phase 2 の決定「2 値なのでメニューは出さない」）。

実際に使うと、押すまで何になるか分からないのが分かりにくい。
**タップしたら 2 つを並べて表示し、選んで切り替える**形にする。

- 現在のモードがどちらかは、開かなくてもピルの表示で分かる（従来どおり）
- 開いたときは**両方のモードが並び、現在のモードに印が付く**
- 選び直さずに閉じられる（トグルは押した時点で必ず変わってしまう）

## 現状（コードの事実）

| 項目 | 現状 | 場所 |
| --- | --- | --- |
| ピル本体 | `Button` + `store.setPracticeMode(store.practiceMode.toggled)` | `Conversation/ChatRoomView.swift:108` |
| 切替可否 | `store.canChangePracticeMode`（`session == nil && !canResumeAfterFailure`）で `disabled` + 薄く表示 | `ChatRoomView.swift:124` |
| 切替の副作用 | 末尾の未使用カードを現モードのカードへ差し替え（候補は持ち越しへ戻す） | `ChatRoomStore.setPracticeMode(_:)` |
| トグル用の型 | `PracticeMode.toggled` | `Conversation/PracticeMode.swift:75` |

## 対応方針

`modePill` を `Button` から **`Menu`** に変える。中身は `Picker`（`.pickerStyle(.inline)`）で
`PracticeMode.allCases` を並べ、選択は `store.setPracticeMode(_:)` へ流す。

- インラインの `Picker` にすると**現在のモードに自動でチェックが付く**（自前で印を描かない）
- 各行は `Label(mode.displayName, systemImage: mode.symbolName)` = ピルと同じアイコン・文言
- ピルのラベルに `chevron.down` を足す（押すとメニューが開くことを見た目で示す）
- `disabled` / 薄く表示 / アクセシビリティは従来どおり。ヒントだけ「タップで選択」に変える
- **同じモードを選んだときは何も起きない**（`setPracticeMode` の `guard practiceMode != mode`
  が既に効いているのでカードの差し替えも走らない）

`PracticeMode.toggled` は使い手が居なくなるので**削除する**（対応する単体テストも）。

## 影響範囲

- `Conversation/ChatRoomView.swift` — `modePill` をメニューに
- `Conversation/PracticeMode.swift` — `toggled` 削除
- `EslSpeakingCoachTests/PracticeModeTests.swift` — `toggled` のテスト削除
- `docs/plans/word-practice-mode.md` — Phase 2 の「メニューは出さない」決定を上書きした旨を追記

**変更しない**: 切替の副作用（カード差し替え・候補の持ち越し）・切替可否の判定・store の API。

## テスト方針

- 単体テストは追加しない（メニューの開閉は SwiftUI の描画で、純ロジックが増えないため）。
  既存の `PracticeModeCardTests`（カード差し替え）と `canChangePracticeMode` の担保は変わらない
- ビルド + 既存テスト全件パスを確認する
- シミュレータでピル（chevron 付き）の見た目を確認する。
  **メニューを開いた状態は simctl でタップできないため確認できない** → 実機で確認する

## 実装メモ（2026-07-28）

- `Menu` + `.pickerStyle(.inline)` の `Picker` にした。選択は
  `Binding(get: store.practiceMode, set: store.setPracticeMode)` で store へ流すだけなので、
  切替の副作用（カード差し替え・候補の持ち越し戻し）は従来の経路がそのまま動く
- `.menuStyle(.button)` + `.buttonStyle(.plain)` を付けて、メニュー化してもピルの見た目
  （カプセル・色・高さ 30）が変わらないようにした
- `PracticeMode.toggled` は使い手が居なくなったので削除。単体テストは
  「メニューは `allCases` をそのまま並べる（会話 → 単語の順）」に置き換えた

確認:

- XCTest 198 件 + swift-testing 10 件すべてパス（`toggled` の 1 件を置き換えたので件数は同じ）
- シミュレータでピルが `📖 単語 ⌄` になっている（chevron 付き・従来の見た目のまま）ことを目視確認
- **メニューを開いた状態は未確認**。simctl にタップ手段が無く、osascript 経由のクリックも
  補助アクセス未許可で実行できなかった（-25211）。開いたときの並び・チェックは
  シミュレータを直接触るか実機で確認する

## 受け入れ条件

- [ ] ピルをタップすると会話・単語の 2 つが並び、現在のモードに印が付く
- [ ] 選ぶとそのモードに切り替わり、末尾の未使用カードが差し替わる
- [ ] 同じモードを選んでも何も起きない（カードが作り直されない）
- [ ] セッション中・エラー再開待ちはピルが無効のまま（メニューも開かない）
