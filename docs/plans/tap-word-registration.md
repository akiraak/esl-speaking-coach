# 会話の文面をタップで単語や熟語登録 — 実装プラン

## 目的・背景

会話中・会話後に、Chobi / Naruko や自分の発話に出てきた知らない単語・使いたい熟語を、
その場で単語帳（esl.chobi.me = esl-learning-assistant）へ登録できるようにする。
登録した語は単語モードの母集団（ピッカー・ランダム出題・集計・クイズ）に入り、
「会話で出会った語をそのまま練習に回す」ループを閉じる。

## 関連プランとの整合（共通決定）

3 つのプラン（本プラン / [utterance-replay](utterance-replay.md) / [chat-storage-audit](chat-storage-audit.md)）で
吹き出しへの操作と保存ポリシーを共有する。**変更するときは 3 プラン同時に見直すこと。**

1. **吹き出しのジェスチャ体系**
   - **タップ = 再読み上げ**（AI 吹き出しのみ。utterance-replay 側で実装）
   - **長押し = コンテキストメニュー**（AI・ユーザー両方）: 「単語・熟語を登録」「コピー」
   - `SystemPillRow` の長押しコピー（`ChatRoomComponents.swift:179`）と同型のメニューに揃える。
     単語選択はメニューから開く**シート内**で行い、吹き出し内の語を直接タップ可能にはしない
     （タップ = 再読み上げと衝突するため）
2. **音声ファイルは「直前の 1 セッション」だけローカル保存する**（Caches 配下・セッション ID
   単位。無いものは TTS で再生成。削除は「次セッション開始時 + アプリ起動時」——
   詳細は utterance-replay の「削除設計」）。本プランは音声を扱わない
3. **発話テキスト（`ChatMessageRecord.text`）が唯一の永続情報源**。登録もテキストから行う
   （音声ファイルはいつ消えても再生成できる扱いで、登録機能は依存しない）
4. **本プランは単語帳への「書き込み」を追加する** — CLAUDE.md セキュリティ節の
   「外部に送信するのは…読み取り専用 API への検索クエリだけ」の記述を更新する

## 前提調査（esl-learning-assistant backend の事実。2026-08-01 確認）

対象: `~/Projects/esl-learning-assistant/backend/src/`

- **専用の「単語登録 API」は無い**が、**`POST /api/word-info`（index.ts:413）が実質の登録 API**。
  ボディ `{word, targetLanguage, context?, userTranslation?, regenerate?}`。
  サーバ側で語義を AI 生成（claude-haiku-4-5・同期）して `words` テーブルへ UPSERT する
- **重複登録は安全**: `regenerate` 未指定なら既存行を `cached: true` で即返す（AI を呼ばない・常に 200）
- **原形化 API `POST /api/word-normalize`（index.ts:559）がある**。文脈（`context`）を渡すと
  活用形 → 原形（`inflected`）、句動詞の一部タップ → 句全体（`phrase_part`。例: "picked" in
  "I picked it up" → "pick up"）を提案する。**タップ登録のためにあるような API** なので使う
- **認証は既存と同じ `X-API-Secret`**（`/api/*` 一律。index.ts:90-97）。読み取り専用トークンの
  仕組みは無く、いま Keychain にあるシークレットでそのまま書き込める
- キーの正規化はサーバ側 `trim().toLowerCase()`（db.ts:941-943）。**連続空白の畳み込みは
  クライアント責務**（esl-learning-assistant iOS の `WordRegistrar.normalizeSpacing()` と同じ）。
  こちらは既存の `ChatRoomStore.normalizedWordKey`（小文字化 + 空白畳み込み）を送信前に通せば一致する
- **制約（承知の上で採用）**: コーチアプリの単語帳（`GET /api/words`）の実体は backend の
  `words` テーブルなので、登録した語は**即座に本アプリの母集団に入る**。一方
  esl-learning-assistant **iOS アプリの端末内一覧（SwiftData）には出ない**（同期経路が無い）。
  両アプリの一覧を揃えたくなったら同期 API を別タスクで起こす

## 対応方針

### UI フロー

1. AI / ユーザー吹き出しを**長押し** → コンテキストメニュー「単語・熟語を登録」「コピー」
   （`AIMessageRow` / `UserMessageRow` の bubble Text に `.contextMenu` を追加。
   `ChatRoomComponents.swift:27` / `:57`）
2. 「単語・熟語を登録」→ **登録シート**（新規 `WordRegisterSheet`）
   - 吹き出し全文を**単語チップ**で表示（空白区切り + 前後の句読点を剥がす純関数で分割）
   - チップをタップで選択トグル。**複数選択可・隣接していなくてもよい**
     （"picked … up" のような離れた句動詞は normalize API が文脈から句全体を提案する）
   - 選択が変わるたび `POST /api/word-normalize`（word = 選択語を出現順に半角スペース連結、
     context = 吹き出し全文）→ 提案（原形 / 句全体）を**編集可能なテキストフィールド**に反映。
     API 失敗時は選択語をそのまま入れる（登録は止めない）
   - 「登録」ボタン → `POST /api/word-info`（word = フィールドの値を `normalizedWordKey` で
     正規化、targetLanguage = "ja"、**context = 吹き出し全文**。文脈が語義生成の質を上げる）
   - 結果表示: `cached: false` →「登録しました」/ `cached: true` →「すでに単語帳にあります」。
     生成は同期で数秒かかるのでボタンはスピナー付き無効化
3. セッション中でも使える（ネットワークだけで音声レイヤに触らないため制約不要。
   ただし listening 中にシートを開いても入力の窓は動き続ける、という挙動は許容）

### 実装

- **クライアント**: `WordBook/WordBookClient.swift` に `normalizeWord` / `registerWord`
  （POST 2 本）を追加。既存流儀どおり `makeRequest` / `parseResponse` を static で切り出して
  テスト可能にする。シークレットは既存 `KeychainStore.wordBookAPISecretAccount` を使い回す。
  正確なリクエスト / レスポンス契約は実装時に
  `~/Projects/esl-learning-assistant/backend/src/index.ts:413,559` と
  `ios/.../RemoteWordInfoService.swift:40-50` を見て合わせる
- **UI**: `WordBook/WordRegisterSheet.swift`（View + @Observable ストア）。
  `ChatRoomView` に sheet 表示状態（対象メッセージのテキスト）を追加
- **チップ分割・選択結合**は純関数（`WordRegisterSheet` の static）にしてテストする
- 登録成功後、未使用の単語カードが出ていれば集計（`fetchWordBookTally`）を取り直す（任意。
  カードは差し替えのたびに再取得されるので必須ではない）
- サーバ側 AI（haiku）の課金は単語帳サーバ側の管理であり、本アプリの `UsageStore` には
  記録しない（`docs/specs/ai-cost-map.md` に「単語登録はサーバ側課金・対象外」と注記を足す）

## 影響範囲

- `ChatRoomComponents.swift`（contextMenu 追加）/ `ChatRoomView.swift`（シート表示）
- `WordBookClient.swift`（POST 2 本追加。既存 GET は変更なし）
- 新規 `WordRegisterSheet.swift`
- `CLAUDE.md`（セキュリティ節: 外部送信の記述に「単語帳への登録リクエスト」を追加。
  WordBookClient の「読み取り専用 API クライアント」コメントも更新）
- `docs/specs/ai-cost-map.md`（注記）

## テスト方針

- 単体: リクエスト組み立て（URL・ヘッダ・ボディ・熟語のエンコード）、レスポンスのパース
  （cached の真偽・エラー分類）、チップ分割 / 選択結合 / 正規化の純関数
- E2E: `-wordbook-base-url`（`WordBookClient.swift:100` の既存 DEBUG override）でローカル
  backend（esl-learning-assistant の run-server.sh）に向け、シミュレータで
  長押し → 選択 → 正規化提案 → 登録 → `GET /api/words` に載ることを確認
- 実機: 本番 esl.chobi.me に対して 1 語登録し、単語カードの集計・ピッカーに反映されることを確認

## Phase 分割

- Phase 1: backend 契約の確認 + `WordBookClient` に normalize / register 追加（単体テスト込み）
- Phase 2: 長押しメニュー + 登録シート（チップ選択・正規化提案・登録・結果表示）
- Phase 3: ローカル backend E2E → 実機確認 → CLAUDE.md / ai-cost-map 更新
