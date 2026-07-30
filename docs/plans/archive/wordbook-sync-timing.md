# 調査: 単語の同期タイミングの確認

## 目的・背景

単語帳（esl.chobi.me）で調べた単語が、このアプリの「単語帳から選ぶ」ピッカーに**いつ反映されるのか**を確認する。
（単語帳ピッカー実装直後に TODO 化。キャッシュや生成待ちで古い一覧が出る余地がないかの確認）

## 調査方法

- アプリ側: `WordBookClient` / `WordBookPickerStore` / `WordBookDetailStore` / `ChatRoomView` のシート提示コードを読む
- HTTP 層: 本番 `GET /api/words` のレスポンスヘッダを curl で確認（キャッシュディレクティブの有無）
- サーバ側: 隣のリポジトリ esl-learning-assistant の `wordsApi.ts` / `db.ts` / `index.ts` を読み、単語が DB に載る瞬間を確認

## 結論

**同期は「ピッカーのシートを開いた瞬間」に毎回フルで行われ、ラグ・古いキャッシュの余地はどの層にもない。**
単語帳側で語を調べ終わった（word-info 生成が完了して結果が表示された）瞬間から、次にシートを開けば必ず一覧の先頭に出る。

### 各層の確認結果

| 層 | 確認結果 |
| --- | --- |
| アプリ（一覧） | `.sheet(isPresented:)`（`ChatRoomView.swift:48`）はシート提示のたびに `WordBookPickerView` と `@State` の `WordBookPickerStore` を作り直す → `loadInitial()` が毎回 1 ページ目を取得。ローカルキャッシュ・差分同期なし |
| アプリ（詳細） | `WordBookDetailStore` も画面 push のたびに作り直して取得。キャッシュなし |
| アプリ（シート表示中） | 開きっぱなしの間は自動更新しない。再取得の契機は検索文字列の変更（300ms デバウンス）・追い読み・再試行のみ。**開き直せば反映される**ので実用上問題なし |
| HTTP キャッシュ | `URLSessionConfiguration.ephemeral`（メモリのみ）。サーバ応答に `Cache-Control` / `Expires` / `Last-Modified` が無く weak ETag のみ → freshness を持たないので再検証（304）しか起きず、内容が変われば必ず新しいボディが返る |
| CDN | Cloudflare 経由だが `cf-cache-status: DYNAMIC`（エッジキャッシュなし） |
| サーバ（載る瞬間） | `POST /word-info` が Claude で wordInfo を生成し **同一リクエスト内で同期的に** `upsertStoredWord`。一覧・詳細は同じ `words` 行を読むので「一覧に居るのに詳細が無い」生成待ち状態は存在しない（詳細 404 は削除時のみ） |
| サーバ（並び順） | `ORDER BY updated_at DESC, id DESC`。新しく調べた語・regenerate した語が先頭に来る |

## 対応

確認のみで完了。コード変更なし。

- 将来スコープ外のまま: `updatedSince` での差分同期・ローカルキャッシュ・シート表示中の pull-to-refresh
