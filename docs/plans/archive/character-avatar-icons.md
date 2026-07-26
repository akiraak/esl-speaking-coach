# キャラアイコンの変更（画像アバター化）

## 目的・背景

会話画面のキャラアバターは現在、色付きの円＋頭文字（Chobi=ピンクの C / Naruko=緑の N）のプレースホルダ描画。
用意したイラストアイコンに差し替え、トークルームの見た目を仕上げる。

- 元画像: `~/Downloads/chobi-icon.png` / `~/Downloads/naruko-bg-green-icon.png`（各 1254×1254 PNG, 約 2MB）

## 対応方針

1. `EslSpeakingCoach/Assets.xcassets` を新設し、`chobi-icon` / `naruko-icon` の imageset を追加
   - 元画像は 512×512 に縮小して取り込む（表示は 36pt なので十分。アプリサイズ節約）
   - XcodeGen は sources 配下の `.xcassets` を自動でリソースに含めるため `project.yml` 変更は不要（`xcodegen generate` で反映確認）
2. `ChatCharacter` にアイコンのアセット名（`avatarImageName`）を追加
3. `CharacterAvatar`（ChatRoomComponents.swift）を画像表示に変更
   - `Image` を 36pt の円形クリップ + 白フチ + 影（既存の装飾を踏襲）
   - 頭文字描画 `avatarInitial` は不要になるため削除
   - `avatarColor` は管理画面（SessionListView の話者名の色）で使用中のため残す

## 影響範囲

- `EslSpeakingCoach/Assets.xcassets`（新規）
- `EslSpeakingCoach/Conversation/ChatRoomComponents.swift`
- `EslSpeakingCoach/Conversation/ChatTheme.swift`（avatarInitial 削除）
- `EslSpeakingCoach/Conversation/ChatCharacter.swift`（avatarImageName 追加）

## テスト方針

- `xcodegen generate` 後に `xcodebuild` でビルドが通ること
- シミュレータ（iPhone 17）でトークルームを開き、両キャラのアイコンが円形で表示されることを目視確認
