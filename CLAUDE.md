# esl-speaking-coach

## プロダクト概要

AI と音声で英会話（スピーキング）練習をする **iOS ネイティブアプリ**。作者自身が使い続けるための個人ツール。

- ユーザーが英語で話しかけ、AI が会話相手になって英語で返す。**発話量を稼ぐこと**が第一の目的
- 会話は **英語のみ**。AI は日本語に切り替えず、常に英語で応答する
- ストア公開・多ユーザー対応・課金は **スコープ外**（将来やるとしても今は考えない）

## 技術スタック

| 領域 | 選択 | 備考 |
| --- | --- | --- |
| プラットフォーム | iOS ネイティブ / Swift + SwiftUI | Android は対象外 |
| 音声レイヤ | **未決定**（検証中） | 下記「音声レイヤの方針」参照 |
| 会話・評価の LLM | Claude API（`claude-opus-5`） | アプリから直接呼ぶ |
| データ保存 | 端末内（SwiftData） | サーバーなし。iCloud 同期もしない |
| バックエンド | **なし** | 自分専用前提でアプリから API を直叩きする |

## 音声レイヤの方針

Anthropic の API に**リアルタイム音声（speech-to-speech）のエンドポイントは存在しない**。Claude はテキスト入出力（ストリーミング可）なので、「リアルタイム双方向音声」は以下のいずれかで組む必要があり、**どれを採るかは検証で決める**。

- **A. iOS 内蔵音声 + Claude ストリーミング**: `SpeechAnalyzer`/`SpeechTranscriber`（iOS 26。`SFSpeechRecognizer` の後継）で逐次認識 → Claude のストリーム応答を文単位で `AVSpeechSynthesizer` に流す。外部 SDK 不要、API キーは 1 つ、割り込みも自前実装
- **B. 他社のリアルタイム音声 API**（OpenAI Realtime / Gemini Live）: 真の双方向音声。ただし会話相手が Claude ではなくなる
- **C. ハイブリッド**: 会話は B、セッション後の評価・フィードバックは Claude

**設計上の制約（重要）**: どれに決まっても差し替えられるよう、音声入出力は 1 つのプロトコル境界の裏に隠す。UI と会話ロジックが特定の音声 API に直接依存してはいけない。

- 発話取得 / 読み上げ / 割り込み検知を `VoiceSession` 相当のプロトコルとして定義し、実装を差し替え可能にする
- 会話履歴はプロバイダ非依存の自前モデル（`role` + テキスト）で保持し、API のリクエスト型をそのまま永続化しない

## Claude API の使い方（このプロジェクトの規約）

**Swift の公式 Anthropic SDK は存在しない。** `URLSession` で raw HTTP を叩き、SSE を自前でパースする。他言語 SDK のシグネチャから類推してはいけない。

- エンドポイント: `POST https://api.anthropic.com/v1/messages`
- 必須ヘッダ: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- モデルは **`claude-opus-5`** を使う。日付サフィックスは付けない
- **`temperature` / `top_p` / `top_k` は送ってはいけない**（`claude-opus-5` では 400 になる）
- **assistant prefill（末尾に assistant ターンを置く手法）は使えない**（400）。出力形式を固定したいときは `output_config.format` の structured outputs を使う

### 会話ターン（低レイテンシ優先）

- **ストリーミング必須**（`"stream": true`）。文が確定するたびに読み上げに流す
- `output_config: {"effort": "low"}` を使う。**thinking は無効化しない** — `claude-opus-5` で `thinking: {"type": "disabled"}` にすると `<thinking>` タグが本文に漏れる等の副作用があるため、effort を下げる方で調整する
- `max_tokens` は会話ターンでは意図的に小さく（1024 程度）。長広舌は会話練習として逆効果
- システムプロンプト（コーチの人格・進行ルール）は固定文にして `cache_control: {"type": "ephemeral"}` を付ける。`claude-opus-5` のキャッシュ最小プレフィックスは 512 トークン
- **システムプロンプトに日付やセッション ID を埋め込まない** — プレフィックスが毎回変わりキャッシュが効かなくなる

### フィードバック生成（会話後）

- 会話後の評価では `max_tokens` を大きく取り（ストリーミングなら 16000 以上）、`effort` は `high` を基準にする
- `stop_reason` は必ず確認する。`"refusal"` のときに `content[0]` を読むとクラッシュする

## 開発環境

**このリポジトリは Mac 上にあり、Xcode 26.5 + iOS 26.5 シミュレータでローカル開発が完結する。**

- ここでできること: コード生成・編集、設計、ドキュメント、プラン管理、**ビルド、シミュレータ（iPhone 17）での動作確認**
- コードを変更したら `xcodebuild` でビルドが通ることを確認してから完了とする
- Xcode プロジェクトは XcodeGen で管理する。`project.yml` が正で、`.xcodeproj` は生成物（`xcodegen generate` で再生成、git 管理外）
- 実機でしか検証できないこと（マイク実測、レイテンシ計測、音声認識精度）は実機で確認する。実機未確認の場合はその旨を明示する
- 実機へのビルド＆インストール＆起動は `./run-install-iphone.sh`（無線接続で可）

## セキュリティ

自分専用前提でアプリから API を直叩きするため、**API キーが端末上に存在する**。これは公開アプリでは許容できない構成であり、公開する場合は必ずサーバー経由に変更する。

- API キーは **Keychain** に保存する。`UserDefaults`・plist・ソースコードに書かない
- **API キーをリポジトリにコミットしない。** `.gitignore` と、コミット前の確認を徹底する
- 会話履歴は端末内のみ。外部に送信するのは Claude API へのリクエストだけ

<!-- vibeboard:begin -->
## 開発管理画面 (vibeboard)

ローカル開発時のタスク・プラン管理は [vibeboard](https://github.com/akiraak/vibeboard) で行う。
プロジェクト直下に degit で vendor してある（`./vibeboard/`）。

```bash
# 親プロジェクト直下から
node vibeboard/dist/cli.js --root .
```

`http://localhost:3010` でプロジェクト直下の `docs/plans/`・`docs/specs/`・`TODO.md`・`DONE.md`・`CLAUDE.md`・`README.md` を閲覧・編集できる。

- `Root` タブで `TODO.md` / `DONE.md` / `CLAUDE.md` / `README.md` をプレビュー表示・編集できる
  - 編集は楽観ロック（mtime チェック）付き。外部で先に更新されていた場合は保存時に 409 を返し、リロード / 手元維持 / 強制上書き を選べる
  - `fs.watch` + 2 秒ポーリングで外部変更を検知し、SSE でクライアントへ即時反映する
- ローカル開発専用（本番管理画面とは独立）
- ポート変更は `--port` または `VIBEBOARD_PORT` 環境変数で指定可能

## タスク管理ルール

- タスクは `TODO.md` で管理する
- タスクが完了したら `TODO.md` から該当項目を削除し、`DONE.md` に移動する
- `DONE.md` には完了日を `YYYY-MM-DD` 形式で付けて記録する
- 新しいタスクが発生したら `TODO.md` の適切なセクションに追加する
- タスクの実施前に `TODO.md` を確認し、優先度の高いものから着手する
- コミット時に `TODO.md` を確認し、実装した機能に対応するタスクがあれば `DONE.md` に移動する

## 作業着手ルール

作業（実装・調査いずれも）を始めるときは、コードに手を入れる前に以下を行う。

1. **プランファイルを作成する**: `docs/plans/<task-name>.md` に実装プラン or 調査プランを作成する
   - 目的・背景、対応方針、影響範囲、テスト方針を最低限記載する
   - 複数 Phase / Step に分かれる場合はファイル内でも Phase / Step を明示する
2. **`TODO.md` に該当項目があるか確認する**
   - 無ければ適切なセクションに追加する
   - 既存項目があれば、その項目に作成したプランファイルへのリンクを追記する（例: `[plan](docs/plans/<task-name>.md)`）
3. **複数 Phase / Step がある場合は `TODO.md` に子タスクとして追加する**
   - 親項目の下にインデントしたチェックボックスで Phase / Step を列挙する
   - Phase / Step が完了するごとにチェックを入れ、全完了で親項目を `DONE.md` に移す
4. **作業完了時の後片付け**
   - 親タスクを `DONE.md` に移動する
   - 対応するプランファイルは `docs/plans/archive/` に移動する
<!-- vibeboard:end -->

### このプロジェクト固有の vibeboard 設定

ポート 3010 / 3011 は別プロジェクトが使用しているため、`vibeboard.config.json` でポートを **3012** に固定している。管理画面は `http://localhost:3012` で開く。起動は `./run-vibeboard.sh`（既存プロセスがポートを掴んでいれば停止してから起動する）。
