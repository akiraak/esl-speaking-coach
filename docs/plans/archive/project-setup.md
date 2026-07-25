# プロジェクトセットアップ(実装プラン)

## 目的・背景

- 音声レイヤ検証([voice-layer-spike](../voice-layer-spike.md))を含む全タスクの前提となる Xcode プロジェクトがまだ存在しない
- 開発環境が WSL から Mac に変わり、`CLAUDE.md` の「開発環境の制約」が実態と乖離している。現環境は **Mac + Xcode 26.5 + iOS 26.5 シミュレータ**で、ローカルでビルド・シミュレータ確認まで完結できる
- スパイクで Claude API を叩く前に、API キーを安全に保管する仕組み(Keychain)が必要

## 対応方針

### Phase 1: `CLAUDE.md` の開発環境制約を更新

- 「開発環境の制約」セクションを Mac 前提に書き換える
  - できること: コード生成・編集、ビルド、シミュレータでの動作確認
  - 「ビルドが通ることを確認したと書いてはいけない」ルールを撤廃し、ローカルでのビルド確認を標準にする
  - 実機のみで検証できること(マイク実測、レイテンシ計測、音声認識精度)は引き続き実機確認とし、未実機確認の場合はその旨を明示する
- `docs/plans/voice-layer-spike.md` の「検証方法」にある WSL 前提の記述も合わせて修正する

### Phase 2: Xcode プロジェクト作成 + `.gitignore`

- プロジェクト生成は **XcodeGen**(インストール済み: `/opt/homebrew/bin/xcodegen`)を使い、`project.yml` で宣言的に管理する
  - `.xcodeproj` は生成物として `.gitignore` に入れ、`project.yml` を正とする
- 構成:
  - アプリ名 / ターゲット名: `EslSpeakingCoach`
  - SwiftUI アプリテンプレート相当の最小構成(`App` + 1 画面)
  - デプロイメントターゲット: iOS 18 を暫定とし、作者の実機 iOS バージョンに合わせて調整する
  - `Info.plist` に `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` を先行して記載(スパイク Phase 1 で必要になるため)
- `.gitignore` に Xcode 関連を追記: `xcuserdata/`, `DerivedData/`, `build/`, `*.xcuserstate`, `.DS_Store`, `*.xcodeproj`(XcodeGen 生成物), ローカル設定ファイル(`*.xcconfig.local`, `.env*`)
- ビルド・起動をシミュレータ(iPhone 17)で確認する

### Phase 3: API キーの Keychain 保存

- `KeychainStore`(小さなラッパ)を実装する
  - `kSecClassGenericPassword` で保存 / 読み出し / 削除
  - `UserDefaults`・plist・ソースコードには一切書かない(`CLAUDE.md` のセキュリティ方針)
- 登録手段: SwiftUI の設定画面(`SecureField` にペーストして保存)を最小実装する
  - 起動時にキー未設定なら設定画面へ誘導する
- 将来スパイク Phase 2 で OpenAI キーが増えることを想定し、キーをアカウント名(例: `anthropic-api-key`)で区別できる API にしておく

## 影響範囲

- 新規: `project.yml`、アプリソース一式(`EslSpeakingCoach/`)、`KeychainStore`、設定画面
- 更新: `CLAUDE.md`(開発環境の制約)、`.gitignore`、`docs/plans/voice-layer-spike.md`(検証方法の環境記述)
- このプラン完了で voice-layer-spike Phase 1 に着手できる状態になる

## テスト方針

- シミュレータ(iPhone 17 / iOS 26.5)でビルドと起動を確認する
- Keychain: 保存 → アプリ再起動 → 読み出しの一連をシミュレータで確認する
- API キーがリポジトリに混入していないことを `git status` と `git grep` で確認してからコミットする
