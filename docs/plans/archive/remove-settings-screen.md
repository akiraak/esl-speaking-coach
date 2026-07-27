# 設定画面の削除と管理画面ボタンの移設

## 目的・背景

API キーは `.secrets/` + 起動引数（`-seed-<provider>-key`）で Keychain へ流し込む運用に固まっており、
アプリ内の設定画面（Anthropic キーの手入力）は使われていない。UI を減らすため削除する。
同時に、ヘッダの ⋯ メニューにしかなかった「管理画面」を、設定ボタン（⚙）があった右端の位置へ
単独ボタンとして出し、1 タップで開けるようにする。

## 対応方針

1. `EslSpeakingCoach/Settings/SettingsView.swift` を削除（ディレクトリごと）
2. `ChatRoomView`
   - `isShowingSettings` state・`.sheet`・`.onAppear` のキー未設定時の自動表示を削除
   - ヘッダの ⋯ メニュー（中身は「管理画面」1 項目のみ）と ⚙ ボタンを、
     `chart.bar.doc.horizontal` の管理画面ボタン 1 個に置き換える
3. `ChatRoomStore.isAnthropicKeyMissing` は参照が無くなるので削除
4. 仕様書 `docs/specs/screen-layout.md` のヘッダ記述を同期

## 影響範囲

- `EslSpeakingCoach/Settings/SettingsView.swift`（削除）
- `EslSpeakingCoach/Conversation/ChatRoomView.swift`
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift`
- `docs/specs/screen-layout.md`

XcodeGen の sources はディレクトリ指定なので `project.yml` の変更は不要。

## テスト方針

- `xcodebuild` でビルド + 既存ユニットテスト全件パス
- シミュレータでヘッダの管理画面ボタンから管理画面が開くことを確認
