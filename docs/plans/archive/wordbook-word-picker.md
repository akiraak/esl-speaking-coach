# 単語帳（esl.chobi.me）からの出題 — 実装プラン

> **進捗（2026-07-29）**: Phase 1・2 実装完了。Phase 3 は単体テストとシミュレータ E2E
> （ローカル backend に向けた `-wordbook-base-url` 上書きで一覧 / 検索 / タップ開始 / 401 /
> シークレット未設定を確認）・仕様書更新まで完了。
> 実装当日は本番 `GET /api/words` が未デプロイで 404 だったが、同日中に esl-learning-assistant
> 側をデプロイして解消し、本番疎通（HTTP 200・total=185）とシミュレータでの本番一覧表示を確認。
> 実機確認もユーザーが実施して OK（同日）。**完了**。

## 目的・背景

単語モードの出題は現在「手入力」と「前に練習した語のピル」だけで、**新しく練習する語は毎回
自分で思いついて打ち込む**必要がある。一方、隣のプロジェクト
[esl-learning-assistant](../../../esl-learning-assistant/)（https://esl.chobi.me）には
iOS アプリで登録してきた単語が `words` テーブルに蓄積されており、**他アプリからの読み取り専用
参照 API（`GET /api/words`）が用意済み**（2026-07 追加。設計は
`../esl-learning-assistant/docs/plans/archive/word-info-reference-api.md`）。

この API を単語モードの出題ソースにして、**登録済みの単語帳から選んで練習を始められる**ようにする。

`docs/specs/word-practice.md` は「出題ソース = ユーザー入力のみ。マイ単語帳はスコープ外」と
決めているため、本タスクはその決定の更新を含む（実装完了時に仕様書へ反映する）。

## API 仕様（2026-07-29 調査済み）

`../esl-learning-assistant/backend/src/index.ts:712` / `wordsApi.ts`。読み取り専用で AI は呼ばれない
（課金・書き込みなし）。

- **エンドポイント**: `GET https://esl.chobi.me/api/words`
- **認証**: `/api/*` 共通の **`X-API-Secret` ヘッダ**（生の共有シークレット。`Bearer` プレフィックスなし。
  不一致は 401 `{"error":"unauthorized"}`）。疎通確認は `GET /api/ping` → `{"ok":true}`
- **シークレットの値**: 本番（esl.chobi.me）の `API_SECRET` は
  `../esl-learning-assistant/.env.prod`（git 管理外のローカルコピー）にある。
  **`backend/.env` の値はローカル開発サーバ用の別物**なので取り違えない。
  16 文字以上・`[A-Za-z0-9_-]` のみ（サーバが起動時に強制）なのでヘッダに素で載せられる
- **クエリ**（すべて省略可・不正値は 400）:
  | param | 説明 |
  | --- | --- |
  | `targetLanguage` | 完全一致（本アプリは `ja` 固定で送る） |
  | `q` | 正規化キー（trim + 小文字化）への部分一致検索 |
  | `limit` / `offset` | 1〜500（既定 100）/ 0〜（既定 0）。`total` 付きのオフセットページング |
  | `updatedSince` | ISO 8601 差分取得（今回は使わない） |
  | `includeInfo` | `true` で全 `wordInfo` 同梱（今回は使わない） |
- **レスポンス**: `{ total, limit, offset, words: [...] }`。並びは **`updated_at` 降順**（新しい順）。
  各要素:
  ```json
  {
    "word": "get around to",        // 正規化済み（trim + 小文字）
    "targetLanguage": "ja",
    "meaning": "〜する時間を見つける",  // 第 1 義。壊れた行は null（エラーにならない）
    "partOfSpeech": "phrasal verb", // 第 1 義。null あり
    "cefrLevel": "B2",              // null あり
    "createdAt": "2026-07-01T00:00:00.000Z",
    "updatedAt": "2026-07-20T00:00:00.000Z"
  }
  ```
- 関連: `GET /api/words/:word?targetLanguage=ja`（1 語の詳細 = 全 `wordInfo`。熟語は URL エンコード）。
  今回のピッカーでは使わないが、TODO の「単語会話用の辞書機能」で使える
- CORS ミドルウェアなし（ネイティブアプリからの直叩きなので無関係）。Cloudflare 経由

## 決定サマリ

| 項目 | 決定 |
| --- | --- |
| 導線 | 単語カードに **「単語帳から選ぶ」ボタン**を追加（「単語を入力」の隣）→ シートで一覧 |
| シートの中身 | 検索フィールド + 単語リスト（英語 + 第 1 義 + CEFR）。**タップで即セッション開始**（ピルと同じ流儀。シートを閉じて `startSession`） |
| 取得タイミング | シートを開くたびに取得（ローカルキャッシュ・差分同期はしない）。ローディング / エラー + 再試行はシート内で完結（カードの `isLoading` / `errorText` は使わない） |
| 検索 | サーバの `q`（デバウンス付き）。ページングは `offset`（リスト末尾到達で追い読み） |
| 固定値 | base URL `https://esl.chobi.me` / `targetLanguage=ja` はハードコード（自分専用アプリの既存流儀） |
| シークレット管理 | 既存規約どおり **Keychain**。`.secrets/wordbook-api-secret` + `-seed-wordbook-key` でシード |
| 命名 | 外部サービスは「単語帳 = WordBook」と呼ぶ（`WordBookClient` / `EslSpeakingCoach/WordBook/`） |
| 既存導線 | 手入力・前に練習した語のピルは**そのまま残す**（単語帳はあくまで追加の出題ソース） |

## 対応方針

### Phase 1: クレデンシャルの配管と API クライアント

1. `KeychainStore` に `wordBookAPISecretAccount` を追加（`Support/KeychainStore.swift:12-14` の並び）
2. `DebugLaunchArguments.keyAccounts` に `("-seed-wordbook-key", "-delete-wordbook-key", ...)` を追加
   （`Support/DebugLaunchArguments.swift:7-11`）
3. `run-simulator.sh` / `run-install-iphone.sh` に
   `add_seed_arg .secrets/wordbook-api-secret -seed-wordbook-key` を追加
4. `.secrets/wordbook-api-secret` を作成（値は `../esl-learning-assistant/.env.prod` の `API_SECRET`。
   git 管理外なのはディレクトリごと ignore 済みで担保）
5. `EslSpeakingCoach/WordBook/WordBookClient.swift`（新規）: `TopicSuggestionClient` と同じ形
   - `Sendable` struct + `URLSessionConfiguration.ephemeral`（タイムアウト明示）+
     専用 `WordBookError`（`missingSecret` / `httpError(statusCode:body:)` / `decodingFailed` など）
   - `fetchWords(query:offset:) async throws -> WordBookPage`（`total` / `words: [WordBookEntry]`）
   - リクエスト組み立て（クエリの percent-encode 含む）と JSON デコードは
     `static func makeRequest(...)` / `parseResponse(...)` に分離して単体テスト可能に
   - `WordBookEntry` は `word` / `meaning` / `partOfSpeech` / `cefrLevel` だけ持つ自前モデル
     （API のレスポンス型をそのまま UI に流さない）
6. CLAUDE.md セキュリティ節の provider 列挙（anthropic / openai / gemini）に wordbook を追記

### Phase 2: 単語カードからのピッカー UI

1. `ChatRoomComponents.swift` の `wordBody`（`:292-334`）に「単語帳から選ぶ」ボタンを追加
   （未使用カードのみ。「単語を入力」と並べる）
2. `WordBook/WordBookPickerView.swift` + `WordBookPickerStore.swift`（新規、`@MainActor @Observable`）
   - 状態: `loading / loaded(entries, total) / failed(message)`。再試行ボタン
   - 検索: `TextField` + 300ms 程度のデバウンスで `q` を再取得。ページング: 末尾行の `onAppear` で
     `offset` を進めて追い読み（`total` に達したら止める）
   - 行タップ → シートを閉じて `store.startSession(topic: word, fromCard: cardID)`
     （ピルタップ `ChatRoomView.swift:269` と同じ経路。以後の保存・ピル化は既存のまま）
   - client は init 注入（プロトコルか closure）にしてフェイクで単体テスト
3. シークレット未設定時はシート内に案内を出す（ボタン自体は常に表示。DEBUG はシードで入るので
   実際に見るのは素の TestFlight 的な状況だけ）

### Phase 3: 検証・ドキュメント・後片付け

1. `xcodegen generate` → `xcodebuild` ビルド + 全テストがグリーン
2. シミュレータ E2E: `./run-simulator.sh -practice-mode word` でシートを開き、
   実 API（シード済みシークレット）で一覧 → 検索 → タップ → `[New word: <語>]` でセッションが
   始まることを確認。401（わざと壊したシークレット）・機内モードのエラー表示も確認
3. 実機確認（ユーザー): 単語帳からの選択 → 練習 → 終了後にその語がピルへ入ること
4. `docs/specs/word-practice.md` 更新: 決定サマリ「出題ソース」、差分早見表と画面節のカード行、
   「やらないこと」からマイ単語帳連携を外し本仕様への参照を追記
5. TODO → DONE、本プランを `docs/plans/archive/` へ

## 影響範囲

- 新規: `EslSpeakingCoach/WordBook/`（`WordBookClient.swift` / `WordBookPickerView.swift` /
  `WordBookPickerStore.swift`）、`EslSpeakingCoachTests/WordBookClientTests.swift` /
  `WordBookPickerStoreTests.swift`、`.secrets/wordbook-api-secret`
- 変更: `Support/KeychainStore.swift`、`Support/DebugLaunchArguments.swift`、
  `Conversation/ChatRoomComponents.swift`（wordBody）、`Conversation/ChatRoomView.swift`（シート表示）、
  `run-simulator.sh` / `run-install-iphone.sh`、`CLAUDE.md`、`docs/specs/word-practice.md`
- 触らないもの: セッション開始以降の全経路（`startSession` / system prompt / 保存 / フィードバック）、
  `project.yml`（sources はフォルダ参照なので再生成のみ）、esl-learning-assistant 側（API は実装済み）

## テスト方針

- 単体テスト: `makeRequest`（クエリ組み立て・ヘッダ・熟語のエンコード）/ `parseResponse`
  （正常 JSON・`meaning: null`・壊れた JSON・401/500 のエラー変換）/ ピッカー store
  （フェイク client でローディング → 成功・失敗 → 再試行・検索でのリセット・ページング境界）
- 通信の実挙動（本番 API・Cloudflare）はシミュレータで実シークレットを使って手動確認。
  実機はレイテンシと操作感の確認のみ（ロジック差はない）

## スコープ外（今回はやらない）

- 練習済みの語のマーク表示・重複回避・SRS 連動（単語帳側の `reviewState` は API に出てこない）
- `updatedSince` での差分同期・ローカルキャッシュ・オフライン対応
- `GET /api/words/:word` の詳細表示（TODO の「単語会話用の辞書機能」で扱う）
- 単語帳への書き込み（練習した語を esl-learning-assistant 側へ登録する逆方向連携）
