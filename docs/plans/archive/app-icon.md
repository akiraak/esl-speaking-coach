# アプリアイコンの作成

## 目的・背景

ホーム画面に表示されるアプリアイコンが未設定（`AppIcon.appiconset` に画像なし）。
Naruko のイラスト（`/Users/akiraak/Downloads/naruko-icon.png`、1254x1254 PNG・アルファなし）をアプリアイコンに設定する。

## 対応方針

1. 元画像を `sips` で 1024x1024 にリサイズし、`EslSpeakingCoach/Assets.xcassets/AppIcon.appiconset/AppIcon.png` として配置する
   - Xcode の single-size 運用（既存 Contents.json が `universal / ios / 1024x1024` の 1 スロット構成）をそのまま使う
   - アルファチャンネルなしを維持する（App Store 要件と同等の形にしておく）
2. `Contents.json` に `filename: AppIcon.png` を追記する
3. `xcodegen generate` → `xcodebuild` でビルドが通ることを確認する

## 影響範囲

- `EslSpeakingCoach/Assets.xcassets/AppIcon.appiconset/` のみ。コード変更なし

## テスト方針

- `xcodebuild` でビルド成功を確認
- シミュレータ（iPhone 17）にインストールしてホーム画面のアイコン表示を確認
