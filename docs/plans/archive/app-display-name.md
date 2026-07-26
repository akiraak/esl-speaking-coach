# アプリ表示名を変更

## 目的・背景

ホーム画面のアプリ名が製品名の `EslSpeakingCoach` のまま（`CFBundleDisplayName` 未設定）で、途中で省略されて表示される。表示名を **ESL Talk** に変更する（20 候補から選定。キャラ名は入れない・ESL を入れる・会話系、の条件）。

## 対応方針

- `project.yml` のアプリターゲット settings に `INFOPLIST_KEY_CFBundleDisplayName: "ESL Talk"` を追加する
  （Info.plist は `GENERATE_INFOPLIST_FILE` による生成のため、build setting で注入する）
- `xcodegen generate` でプロジェクトを再生成する

## 影響範囲

- `project.yml` のみ。コード・バンドル ID・スキーム名は変更しない

## テスト方針

- ビルドが通ること
- ビルド成果物の Info.plist に `CFBundleDisplayName = "ESL Talk"` が入っていることを確認
- ホーム画面での実際の見え方はシミュレータ / 実機で確認
