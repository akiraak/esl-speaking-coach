# トーク画面のデバッグ表示を会話ログへ移す

## 目的・背景

トーク画面のタイムラインに、会話練習には不要な技術情報が混ざっている。

- DEBUG 限定のレイテンシ計測行（`体感 1234ms | 無音待ち … | STT確定 … | TTFT …`）
- 技術的な通知ピル（`STT へ接続中… (gpt-4o-transcribe)` / `STT 再接続完了` /
  `stop_reason: end_turn` / `STT プロンプトのエコーを破棄しました` / `サーバ通知: …` など）

会話中の見た目からは消したいが、レイテンシ・接続まわりの調査には引き続き必要なので、
管理画面の会話ログ（セッション詳細）に残す。

## 対応方針

1. 永続化: `ChatSessionLogRecord`（@Model）を追加し、セッションに紐づけて記録する
   - `kind`（`metrics` / `notice` / `error`）+ `text` + `createdAt` + `orderIndex`
   - `AppModelContainer` の schema に追加（既存ストアへの追加は additive なので軽量マイグレーションで済む）
2. `ChatHistoryStore`: `appendLog(kind:text:)` / `logs(sessionID:)` を追加
3. `ChatRoomStore.handle(event:)`
   - `.turnMetrics` → タイムラインへの `systemNotice` 追加をやめ、ログへ保存（`#if DEBUG` も外す）
   - `.info` → タイムラインへ出さずログへ保存
   - `.failure` → 従来どおりタイムラインに「エラー: …」を出し、あわせてログにも保存
4. 管理画面 `SessionDetailView`: 「会話」セクションで発話とログを時系列にマージ表示する
   （ログはグレーの小さいキャプション行。レイテンシ計測はそれを引き起こした AI 発話の直後に並ぶ）

## 影響範囲

- `EslSpeakingCoach/Persistence/ChatHistoryModels.swift`（`ChatSessionLogRecord` 追加）
- `EslSpeakingCoach/Persistence/AppModelContainer.swift`
- `EslSpeakingCoach/Persistence/ChatHistoryStore.swift`
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift`
- `EslSpeakingCoach/Admin/SessionListView.swift`
- 仕様書 `docs/specs/screen-layout.md`

## テスト方針

- `ChatHistoryStoreTests` にログの保存・取得（セッション削除で cascade 削除されること含む）のテストを追加
- ビルド + 単体テスト全件パス
- シミュレータでトーク画面に計測行・技術通知が出ないこと、管理画面の会話ログに記録されることを確認
