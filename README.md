# esl-speaking-coach

AI と音声で英会話（スピーキング）練習をする **iOS ネイティブアプリ**（表示名 "ESL Talk"）。
作者自身が使い続けるための個人ツールで、ストア公開・多ユーザー対応・課金はスコープ外。

- ユーザーが英語で話しかけ、AI キャラ 2 人が会話相手になって英語で返す。**発話量を稼ぐこと**が第一の目的
- 会話は英語のみ。日本語は「訳の表示」とセッション後フィードバックにだけ使う
- バックエンドなし。アプリから Anthropic / OpenAI / Google Gemini の API を直叩きし、データは端末内（SwiftData）にのみ保存する

## 主な機能

| 機能 | 概要 |
| --- | --- |
| グループトーク | 起動即チャット画面。ホストの **Chobi**（先生役・ピンク）と仲間の生徒 **Naruko**（薄い緑）の 2 キャラと LINE 風グループトークで会話する |
| 音声 / テキスト入力 | マイクボタンで音声モード（ハンズフリー連続・サーバ VAD・barge-in 可）、キーボードボタンでテキストモード。どちらでも AI は音声で返す |
| トピック提案 | Claude がトピック候補 3 件（日本語タイトル + フック 1 文）を生成してカードで提示。再生成・自作トピックのほか、固定候補「話しかける」（AI が口火を切らず、最初のターンを学習者から始める）にも対応。ジャンル × 話し方 × 難易度はアプリ側でサンプリングして割り当て、候補が単調にならないようにしている |
| セッション後フィードバック | セッション終了時に会話全文を `claude-sonnet-5` で評価し、日本語のフィードバックカードをタイムラインへ投稿する |
| 会話の訳 | 下端バーの「翻訳」トグルで、各吹き出しの下に日本語訳を表示。訳は端末内に永続化する |
| キャラの記憶 | セッション終了ごとに記憶ノートをローリング更新し、次のセッションの先頭 user メッセージへ合成する |
| 管理画面 | 会話ログ（発話 + 調査用の計測 / 通知 / エラー）、AI 利用料金、記憶ノートの閲覧 |

設定画面は持たない（API キーは後述の `.secrets/` 運用でシードする）。

## 技術スタック

| 領域 | 選択 |
| --- | --- |
| プラットフォーム | iOS 26 / Swift 6 + SwiftUI（iPhone のみ） |
| STT | OpenAI `gpt-4o-transcribe`（Realtime API の transcription セッション / WebSocket）。無音判定 800ms のサーバ VAD |
| 会話 LLM | Claude Messages API `claude-sonnet-5`（ストリーミング + 文単位 TTS。台本方式で 2 キャラ分を 1 回の呼び出しで生成） |
| フィードバック / トピック生成 / 記憶更新 | `claude-sonnet-5` |
| 翻訳 | `claude-haiku-4-5` |
| TTS | Gemini Flash TTS（`streamGenerateContent` SSE / 24kHz PCM16 LE）。聞き比べ用に `gpt-4o-mini-tts` へ切替可 |
| データ保存 | 端末内 SwiftData（サーバー・iCloud 同期なし） |
| プロジェクト管理 | XcodeGen（`project.yml` が正、`.xcodeproj` は生成物） |

音声入出力は `VoiceSession` プロトコルの裏に隠し、STT / TTS 単体も
`StreamingSpeechTranscriber` / `SentenceTTSClient` で個別に差し替えられるようにしてある。
会話履歴はプロバイダ非依存の自前モデル（`role` + テキスト）で保持する。

Swift の公式 Anthropic SDK は無いため、`URLSession` で raw HTTP を叩き SSE を自前でパースしている。
API の使い方（送ってはいけないパラメータ、キャッシュ、structured outputs など）の規約は
[CLAUDE.md](CLAUDE.md) を参照。

## ディレクトリ構成

```
EslSpeakingCoach/
├── App/            アプリのエントリポイント
├── Conversation/   トーク画面（View / Store / テーマ / トピックカタログ）
├── Claude/         Claude API クライアント（会話・トピック・フィードバック・記憶・翻訳）
├── Voice/          音声レイヤ（VoiceSession、マイク取得、文分割、再接続）
│   └── CloudPipeline/  OpenAI STT / Gemini・OpenAI TTS / ストリーミング再生
├── Persistence/    SwiftData モデルとストア（会話履歴・記憶・利用料金）
├── Usage/          AI 利用料金の記録と単価表
├── Admin/          管理画面（会話ログ / 料金 / 記憶）
└── Support/        Keychain、DEBUG 起動引数
EslSpeakingCoachTests/   ユニットテスト
docs/
├── specs/          仕様書（画面・会話設計・フィードバック・料金マップ）
└── plans/          作業中の実装 / 調査プラン（完了分は archive/）
```

## セットアップ

前提: macOS + Xcode 26.5 / iOS 26.5 シミュレータ、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

1. API キーを `.secrets/` に 1 行のプレーンテキストで置く（**git 管理外**）:

   ```
   .secrets/anthropic-api-key
   .secrets/openai-api-key
   .secrets/gemini-api-key
   ```

2. シミュレータで起動する:

   ```bash
   ./run-simulator.sh
   ```

   ビルド → インストール → 起動まで行い、`.secrets/` のキーを起動引数 `-seed-<provider>-key`
   経由で Keychain へシードする（DEBUG ビルドのみ有効）。

3. 実機（無線接続で可）:

   ```bash
   ./run-install-iphone.sh
   ```

マイク実測・レイテンシ・音声認識精度は実機でしか確認できないため、これらの検証は実機で行う。

## 開発コマンド

```bash
xcodegen generate                    # project.yml から .xcodeproj を再生成

# ビルド
xcodebuild -project EslSpeakingCoach.xcodeproj -scheme EslSpeakingCoach \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# ユニットテスト
xcodebuild -project EslSpeakingCoach.xcodeproj -scheme EslSpeakingCoach \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

./run-simulator.sh                   # シミュレータへビルド＆インストール＆起動
./run-install-iphone.sh              # 実機へビルド＆インストール＆起動
./run-vibeboard.sh                   # タスク / プラン管理画面（http://localhost:3012）
```

`run-simulator.sh` には追加の起動引数をそのまま渡せる（例: `-start-conversation -send-text "Hello coach"`）。

## ドキュメント

| ファイル | 内容 |
| --- | --- |
| [CLAUDE.md](CLAUDE.md) | プロダクト方針、音声レイヤの決定、Claude API 利用規約、開発ルール |
| [docs/specs/screen-layout.md](docs/specs/screen-layout.md) | 画面レイアウト・タイムライン・入力バー・ビジュアルデザイン |
| [docs/specs/conversation-design.md](docs/specs/conversation-design.md) | キャラクター、台本方式のターン進行、トピック生成、翻訳 |
| [docs/specs/session-feedback.md](docs/specs/session-feedback.md) | セッション後フィードバックの内容と生成仕様 |
| [docs/specs/ai-cost-map.md](docs/specs/ai-cost-map.md) | どの操作でどの API に課金が発生するか + 単価表 |
| [TODO.md](TODO.md) / [DONE.md](DONE.md) | タスク管理 |

## セキュリティ

自分専用前提でアプリから API を直叩きするため、**API キーが端末上に存在する**。
これは公開アプリでは許容できない構成であり、公開する場合は必ずサーバー経由に変更すること。

- API キーは Keychain にのみ保存する（`UserDefaults`・plist・ソースコードに書かない）
- `.secrets/` は git 管理外。API キーをリポジトリにコミットしない
- 会話履歴は端末内のみ。外部へ送信するのは音声・会話系 API へのリクエストだけ

## ライセンス

MIT License（[LICENSE](LICENSE)）。
