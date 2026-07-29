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
| 音声レイヤ | クラウド STT / TTS + Claude のターン制（**決定**） | STT: OpenAI `gpt-4o-transcribe`、TTS: Gemini Flash TTS。下記「音声レイヤの方針」参照 |
| 会話・評価の LLM | Claude API（会話・トピック生成: `claude-sonnet-5` / 評価: `claude-opus-5`） | アプリから直接呼ぶ |
| データ保存 | 端末内（SwiftData） | サーバーなし。iCloud 同期もしない |
| バックエンド | **なし** | 自分専用前提でアプリから API を直叩きする |

## 音声レイヤの方針

**2026-07-25 決定**: 3 方式（クラウド STT/TTS + Claude / OpenAI Realtime / Gemini Live）をプロトタイプして実機比較した結果、**クラウド STT / TTS + Claude ストリーミングのターン制パイプライン**を採用した。会話相手を Claude に保てることが決め手。個々のモデル・voice・パラメータは実装フェーズで調整する。

| 役割 | 採用 | 備考 |
| --- | --- | --- |
| STT | OpenAI `gpt-4o-transcribe`（Realtime API の transcription セッション / WebSocket） | `language: en` + prompt ヒントで英語固定（短い発話の言語誤判定対策） |
| 発話終端・barge-in | transcription セッションのサーバ VAD | 無音判定 800ms を明示指定（既定 200ms は ESL 学習者に短すぎる） |
| 会話 LLM | `claude-sonnet-5`（下記規約どおりストリーミング + 文単位 TTS） | 2026-07-25 に opus-5 / sonnet-5 / haiku-4-5 を比較して決定（記録: `docs/plans/archive/spike-conversation/`） |
| TTS | Gemini Flash TTS（現行 `gemini-3.1-flash-tts-preview`。`streamGenerateContent` SSE、24kHz PCM16 LE） | モデル・voice は調整中。聞き比べ用に `gpt-4o-mini-tts` へ切替可 |

- Anthropic の API に**リアルタイム音声（speech-to-speech）のエンドポイントは存在しない**。この構成は Anthropic 公式の Claude アプリ音声モードと同型
- 不採用にしたもの: iPhone 純正音声系（STT のモデル DL・シミュレータ検証不可・TTS 品質）、OpenAI Realtime / Gemini Live の speech-to-speech（会話相手が Claude でなくなる）。検証記録は `docs/plans/archive/voice-layer-spike.md`
- ターン制のため会話中の音声レベルの発音指摘はしない（発音・表現のフィードバックはセッション後にテキストベースで行う）
- **出力経路に `.defaultToSpeaker` を使わない**（2026-07-28 決定）。カテゴリは `.playAndRecord` / `mode: .voiceChat` / options は `AudioRoutePolicy.categoryOptions`（Bluetooth HFP・A2DP・AirPlay を許可）。スピーカーへは「出力が**本体内蔵（受話口 / スピーカー）だけのとき**」に `overrideOutputAudioPort(.speaker)` で寄せ、経路変更のたびに再評価する。**内蔵スピーカーを判定から外さない**（外すと自分のオーバーライドを自分で取り消し、受話口 ⇄ スピーカーの往復で AVAudioEngine が止まり無音になる。`docs/plans/archive/speaker-no-audio.md`）。`.defaultToSpeaker` を付けるとイヤフォン / Bluetooth があっても出力が内蔵スピーカーへ固定される（`AudioRoutePolicy` / `docs/plans/archive/earphone-audio-route.md`）

**設計上の制約（引き続き有効）**: 音声入出力はプロトコル境界の裏に隠す。UI と会話ロジックが特定の音声 API に直接依存してはいけない。

- 発話取得 / 読み上げ / 割り込み検知は `VoiceSession` プロトコルの裏に隠す。さらに STT / TTS 単体も内部境界（`StreamingSpeechTranscriber` / `SentenceTTSClient`）で個別に差し替え可能に保つ
- 会話履歴はプロバイダ非依存の自前モデル（`role` + テキスト）で保持し、API のリクエスト型をそのまま永続化しない

## Claude API の使い方（このプロジェクトの規約）

**Swift の公式 Anthropic SDK は存在しない。** `URLSession` で raw HTTP を叩き、SSE を自前でパースする。他言語 SDK のシグネチャから類推してはいけない。

- エンドポイント: `POST https://api.anthropic.com/v1/messages`
- 必須ヘッダ: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- モデルは会話ターン・トピック生成が **`claude-sonnet-5`**、会話後のフィードバック生成が **`claude-opus-5`**。日付サフィックスは付けない
- **`temperature` / `top_p` / `top_k` は送ってはいけない**（`claude-sonnet-5` / `claude-opus-5` とも 400 になる）
- **assistant prefill（末尾に assistant ターンを置く手法）は使えない**（400）。出力形式を固定したいときは `output_config.format` の structured outputs を使う

### 会話ターン（低レイテンシ優先）

- **ストリーミング必須**（`"stream": true`）。文が確定するたびに読み上げに流す
- `output_config: {"effort": "low"}` を使う。**thinking は無効化しない** — 無効化すると `<thinking>` タグが本文に漏れる等の副作用がある。`claude-sonnet-5` は thinking 未指定で adaptive が既定なのでそのままにし、effort を下げる方で調整する
- `max_tokens` は会話ターンでは意図的に小さく（1024 程度）。長広舌は会話練習として逆効果
- システムプロンプト（コーチの人格・進行ルール）は固定文にして `cache_control: {"type": "ephemeral"}` を付ける。キャッシュ最小プレフィックスは `claude-sonnet-5` が 1024 トークン（`claude-opus-5` は 512）。2 キャラ台本の system prompt は約 2,000 トークンなので満たす
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
- ローカル開発では `.secrets/<provider>-api-key`（git 管理外、1 行のプレーンテキスト。現在は `anthropic-api-key` / `openai-api-key` / `gemini-api-key`）にキーを置くと、`./run-install-iphone.sh` / `./run-simulator.sh` が起動引数 `-seed-<provider>-key` で Keychain へ流し込む（DEBUG ビルドのみ有効）。設定画面からの手入力は不要になる
- 会話履歴は端末内のみ。外部に送信するのは音声・会話系 API（Claude / 検証中の音声プロバイダ）へのリクエストだけ

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
