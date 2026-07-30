# 単語モード: 未練習の語を単語帳からランダムに選んで開始

TODO: 「単語モードで未学習のものを辞書からランダムで選択して会話を始める」

## 目的・背景

単語帳（esl.chobi.me）からの出題は現状すべて手動（ピッカーで一覧から選ぶ / 検索する）。
練習する語を毎回自分で選ぶのは手間で、選びやすい語 = 既に馴染みのある語に偏りがち。
**まだ練習していない語をアプリに選ばせる**ワンタップ導線を作り、単語帳の消化を進める。

## 決定サマリ

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| 「未学習」の定義 | **このアプリの単語モードでまだ練習していない語**（`ChatSessionRecord` mode=word の `topicTitle` に正規化キーで一致しない語） | 単語帳側の学習状態（`reviewState`）は esl-learning-assistant の **iOS アプリ端末内にのみ**あり、サーバー API から取得できない（backend を確認済み。`words` テーブルに学習状態カラムは無い）。word-practice.md でも単語帳側 reviewState は使わないと明記済み |
| ランダム選択の場所 | **クライアント側**。全件取得 → 練習済みを除外 → `randomElement` | `GET /api/words` に random・除外フィルタは無い。個人単語帳（現在 185 語）なので全件取得で十分。`limit=500`（サーバ上限）なら現状 1 リクエスト |
| 未練習が 0 件のとき | **全語からランダムにフォールバック**（診断ログに 1 行残す） | 再練習にも価値があり、ボタンが「何も起きない」体験を避ける |
| UI | 単語カードに 3 つ目のボタン **「ランダムに選ぶ」**（`dice`）。取得中はボタンを無効化 + ProgressView | 「単語を入力」「単語帳から選ぶ」と同列の導線。ピッカーのシートは開かない |
| セッション開始 | 選んだ語で**即開始**（ピル・ピッカー行と同じ `store.startSession(topic:fromCard:)` 経路） | 確認を挟むならピッカーで選べばよい。ランダムは「委ねる」導線なので即開始 |
| エラー表示 | アラート（`WordBookError.errorDescription` を流用。シークレット未設定の案内含む） | ピッカーと同じ文言・同じ分類を保つ |

- 正規化キーは既存の `ChatRoomStore.normalizedWordKey`（小文字化 + 空白畳み込み）を再利用する。
  単語帳側の `word` も正規化済み（trim + 小文字）なので照合はこのキーで足りる
- 練習済みの照合元は `ChatHistoryStore` の mode=word 全セッション（ピルの `recentWords(limit:)` と違い
  **件数を絞らない**。絞ると古い練習語が「未学習」に化ける）。専用の取得メソッドを 1 つ足す
- CEFR・品詞などでの絞り込み、SRS 的な優先度付けはしない（word-practice.md のスコープ外方針を維持）

## 対応方針

### Phase 1: 取得・選択ロジック（UI なし）

- `WordBookClient.fetchAllWords(secret:)` を追加: `limit=500` で offset を回して全ページ取得して結合。
  取得中に total が変わっても止まるよう安全弁（最大ページ数 or 「words が空で total 未達なら打ち切り」）を入れる
- `ChatHistoryStore.practicedWordsAll()`（mode=word 全セッションの `topicTitle`）を追加
- 純関数 `ChatRoomStore.unpracticedWords(all:practiced:)` を追加: 正規化キーで練習済みを除外した
  `[WordBookEntry]`（または `[String]`）を返す。空なら呼び出し側で全語へフォールバック
- ランダム選択は `randomElement(using:)` に `RandomNumberGenerator` を注入できる形にしてテスト可能に保つ

### Phase 2: UI とセッション開始

- `ChatRoomComponents` の単語カードに「ランダムに選ぶ」ボタンを追加（未使用カードのみ有効。
  取得中は 3 ボタンとも無効化して二重タップを防ぐ）
- `ChatRoomView` に取得状態の `@State`（in-flight フラグ / エラーメッセージ）と実行 Task を持たせる。
  シークレットは `KeychainStore.wordBookAPISecretAccount`（ピッカーと同じ読み方）
- 成功したら `store.startSession(topic: word, fromCard: cardID)` で即開始。失敗はアラート
- DEBUG 起動引数 `-start-random-word` を追加（単語カードのランダムボタンをタップした扱い）

### Phase 3: 検証

- 単体テスト:
  - `WordBookClientTests`: `fetchAllWords` のページ結合・打ち切り安全弁（`parseResponse` 流儀のスタブで）
  - `ChatRoomStore` の純関数: 除外（正規化キー・表記ゆれ）・全件練習済みで空・seeded RNG での選択固定
  - `ChatHistoryStoreTests`: `practicedWordsAll()` が mode=word だけを全件返す
- `xcodebuild` でビルド + 既存テスト全パス
- シミュレータ E2E: ローカル backend（esl-learning-assistant の run-server.sh）+ `-wordbook-base-url` +
  `-practice-mode word -start-random-word` で、
  (1) 未練習の語でセッションが始まる（診断ログの `topic=` が練習履歴に無い語）
  (2) 練習済みを増やして除外が効く
  (3) 全語練習済みでフォールバックが動く
  (4) シークレット未設定 / 401 でアラート
- 実機確認はユーザーが実施（本番 esl.chobi.me に対する取得と開始）

## 影響範囲

- 変更: `WordBookClient.swift` / `ChatRoomStore.swift` / `ChatHistoryStore.swift` /
  `ChatRoomComponents.swift` / `ChatRoomView.swift` / `DebugLaunchArguments.swift` + 各テスト
- 触らない: system prompt・セッション開始以降の会話 / 音声 / フィードバックの流れ・
  `WordBookPickerView` / `WordBookPickerStore`（ピッカーのシートは従来どおり独立）

## 未決事項

- ボタン文言（「ランダムに選ぶ」）・アイコン（`dice`）は実装時に見た目で微調整
- 未練習 0 件でフォールバックしたことをユーザーに一言出すか（まずは診断ログのみ。不満が出たら表示を検討）
- 単語帳が数千語規模になったときの全件取得コスト（当面問題にならない。問題になったらサーバー側に
  random API か練習済み除外を持たせる案を再検討）
