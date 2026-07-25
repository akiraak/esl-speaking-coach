# API キーを git 管理外のローカルファイルから設定できるようにする

## 目的・背景

現状、Anthropic API キーはアプリの設定画面から手入力して Keychain に保存する。シミュレータのリセットや実機の再インストールのたびに入力し直すのが手間なので、**リポジトリにコミットしないローカルファイル**にキーを置き、起動スクリプトが自動で流し込む形にする。

## 対応方針

既存の DEBUG 用起動引数 `-seed-anthropic-key`（起動時に Keychain へ保存する仕組み）をそのまま使う。

1. キーの置き場所: `.secrets/anthropic-api-key`（1 行のプレーンテキスト）
2. `.gitignore` に `.secrets/` を追加してコミット対象外にする
3. `run-install-iphone.sh`: ファイルがあれば `devicectl` の起動引数に `-seed-anthropic-key <key>` を付与
4. `run-simulator.sh`（新規）: シミュレータ版のビルド＆インストール＆起動スクリプト。同様にキーをシードし、追加の起動引数（`-start-conversation` 等）もそのまま渡せる
5. `CLAUDE.md` のセキュリティ節にこの仕組みを追記

セキュリティ上の性質は従来と同じ: キーの保存先はあくまで **Keychain**（シードは DEBUG ビルドのみ有効）。ファイルは開発 Mac のローカルにのみ存在し、コミットされない。

## 影響範囲

- `run-install-iphone.sh` / `run-simulator.sh`（新規）/ `.gitignore` / `CLAUDE.md`
- アプリ本体のコード変更なし（既存の `DebugLaunchArguments` を利用）

## テスト方針

- `.secrets/anthropic-api-key` が **無い**状態でスクリプトが従来どおり動くこと
- ダミーのキーを置いた状態で `run-simulator.sh` を実行し、起動後にアプリが「API キー設定済み」になること
- `git status` でキーがコミット対象に出ないこと
