# 画面は縦向きのみ

2026-07-29 起票 / 同日実装完了（仕様は `docs/specs/screen-layout.md`「画面の向き」）。
実装は方針どおり `project.yml` の 1 行のみ。

## 目的・背景

いまアプリは横向きにも回る。トーク画面は縦長の前提で作っていて（吹き出し・カード・下端バー・
入力バー）、横向きにすると 1 画面に入る会話が数行になり、キーボードを出すとほぼ何も見えない。
音声で話す使い方でも端末を寝かせて使うことはないので、**縦向きに固定する**。

現状: ビルド済み `Info.plist` に `UISupportedInterfaceOrientations` が**存在しない**
（`GENERATE_INFOPLIST_FILE: YES` で該当キーを指定していないため）。キーが無いと iPhone では
portrait / landscapeLeft / landscapeRight が既定で許可される = 回ってしまう。

## 対応方針

`project.yml` の app ターゲットに Info.plist 生成キーを 1 行足すだけにする。コードでの
`supportedInterfaceOrientations` オーバーライド（`AppDelegate` / `UIHostingController` 派生）は使わない。

```yaml
INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: UIInterfaceOrientationPortrait
```

- `TARGETED_DEVICE_FAMILY: "1"`（iPhone のみ）なので iPad 用キーは不要
- 上下逆さま（`PortraitUpsideDown`）は入れない。iPhone の既定どおり縦 1 方向だけにする
- `.xcodeproj` は生成物なので `xcodegen generate` で反映する

## 影響範囲

- `project.yml`（1 行追加）
- `docs/specs/screen-layout.md`（縦向き固定であることを明記）
- Swift のコード変更なし・テスト対象のロジック変更なし

## テスト方針

- ビルド後の `EslSpeakingCoach.app/Info.plist` に
  `UISupportedInterfaceOrientations~iphone = [UIInterfaceOrientationPortrait]` が入ることを確認
- シミュレータで端末を横に回してもトーク画面が縦のままであることを確認（スクリーンショット）
- 既存の XCTest が引き続き通ること（ロジック変更は無いので退行確認のみ）
