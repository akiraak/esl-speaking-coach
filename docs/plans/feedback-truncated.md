# セッション後フィードバックの文章が途中で途切れる — 調査プラン

## 目的・背景

会話終了後に投稿されるフィードバックカードの文章（総評 `summary`）が
**途中で途切れた状態**で表示され、バグのように見えた（実機・1 回観測）。

フィードバックはこのアプリの学習価値そのものなので、内容が欠けると
「読めない」だけでなく「間違った訂正が出た」ようにも見える。

クラッシュと違って **OS のクラッシュレポートも例外も残らない**（正常終了扱いで
JSON のデコードも成功している）ため、現状は再現するまで手がかりがゼロ。
まず「次に起きたときに生の応答が残る」状態を作ってから直す。

本プランは「情報回収 → 原因確定 → 対策」の調査プランであり、
Phase 3 の対策内容は原因が確定してから確定させる。

## 現状の生成パスの整理（コードから）

1. `ChatRoomStore.handleSessionFinished()` → `postFeedbackCard(topic:sessionID:)`
   （`ChatRoomStore.swift:519`）。学習者の発話 2 未満はスキップ
2. `sessionTranscript()`（`ChatRoomStore.swift:613`）でタイムラインの現セッション区間から
   話者ラベル付きの会話全文を組み立てる
3. `fillFeedbackCard(cardID:)`（`ChatRoomStore.swift:541`）→
   `SessionFeedbackClient.generateFeedback(apiKey:topic:transcript:)`
4. `SessionFeedbackClient`（`SessionFeedbackClient.swift:102`）
   - `claude-opus-5` / `max_tokens: 16000` / `effort: high` / structured outputs / **ストリーミング**
   - `URLSession.bytes` → `bytes.lines` で 1 行ずつ `ClaudeSSE.parse(line:)` に渡し、
     `text_delta` を `text` へ連結する
   - 全部受け切ってから `parseResult(text:stopReason:)` で JSON をデコードする
5. デコード成功 → カードへ反映 + `historyStore.saveFeedback`（`ChatSessionRecord.feedbackJSON`）

表示側（`ChatRoomComponents.swift:360` `FeedbackCardView.feedbackBody`）は
`Text(feedback.summary)` を `lineLimit` 無しで出しているだけなので、
**表示で切っている箇所は無い** = 途切れは `summary` 文字列そのものに入っている。

## 仮説（優先度順）

### H1. SSE の 1 行が分割されて、その行が黙って捨てられている ★本命

`ClaudeSSE.parse(line:)` は `data:` 行の JSON をデコードできなかったとき
**空配列を返して黙って捨てる**（`ClaudeMessagesClient.swift:184`）。

```swift
guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
```

`bytes.lines`（`AsyncLineSequence`）は LF / CR / CRLF だけでなく
**VT (U+000B) / FF (U+000C) / NEL (U+0085) / LS (U+2028) / PS (U+2029)** でも行を切る。
JSON の文字列中にこれらが**エスケープされずに**含まれていると 1 つの `data:` 行が
2 行に割れ、前半・後半とも JSON として壊れるので **両方とも捨てられる**。

ここが決定的で、捨てられたのが `summary` の**文字列の途中**なら、
残りを連結した全体は **JSON としては壊れていない**（引用符も括弧も失われていない）。
つまり **デコードは成功し、`summary` だけが虫食い / 途切れた状態で表示される** —— 観測された症状と一致する。

- **確認方法**: `data:` 行のデコード失敗を `!!` 付きで記録し、
  同じ生成の生テキストと突き合わせる（Phase 1 で実装）
- 会話ターン側も同じ `ClaudeSSE.parse` を通るので、**会話の吹き出しでも同じ欠落が起きうる**

### H2. 途中でストリームが終わった（接続断 / タイムアウト）

`for try await line in bytes.lines` が **エラー無しで**抜けた場合、
`text` は不完全なまま `parseResult` に入る。この場合ふつうは JSON が壊れて
`malformedContent`（= カードにエラー + 「もう一度生成」）になるはずで、
「途切れた文章が表示される」症状にはならない。ただし
**閉じ括弧まで届いた直後に切れた**ようなケースは残るので候補には残す。

- `timeoutIntervalForRequest = 60` / `timeoutIntervalForResource = 300`（`SessionFeedbackClient.swift:95`）
- **確認方法**: `stop_reason` が nil（`message_delta` を受け取らずに終わった）かどうか

### H3. `max_tokens` 到達で出力が切れた

`stop_reason == "max_tokens"` なら JSON が途中で終わるのでデコードは失敗するはず
（= エラーカード）。ただし thinking を多く使って本文が短く切れる形はありうる。

- **確認方法**: `stop_reason` と出力トークン数を記録すれば一撃で分かる

### H4. モデルの出力そのものが途切れていた

structured outputs でも「文の途中で終わる」文字列を返すことは原理的にありうる。
生テキストが残っていれば H1 と区別できる（生テキストの時点で切れていれば H4）。

### H5. 入力（transcript）側が途切れていた

`sessionTranscript()` は最後の `sessionDivider` 以降を拾うだけで長さ制限は無いが、
会話が長いセッションで input が肥大していないかは記録しておく。

## Phase 構成

### Phase 1: 診断ログの注入（**挙動は変えない**）

次に起きたときに **管理画面（📊）→「診断」タブ**だけで原因が判定できるようにする。
クラッシュ調査（`docs/plans/end-session-crash.md` Phase 0）で入れた `DiagnosticsLog` に相乗りする。

- `ClaudeSSE.parse`: `data:` 行のデコードに失敗したら
  `!! sse: data 行を解釈できず破棄 …` を記録する（**捨てる挙動はそのまま** = H1 なら
  この行が生成中に必ず出る）。`error` イベントの throw も記録する
- `SessionFeedbackClient.generateFeedback`:
  - 開始（topic / transcript の文字数・行数）
  - HTTP 非 200（ステータス + body 先頭）
  - SSE 完了（`stop_reason` / text_delta 件数 / 受信文字数 / in・out トークン）
  - **生の出力テキスト**（上限付き。途切れが生テキスト時点で起きているか = H1 と H4 の切り分け）
  - デコード失敗 / refusal は `!!` 付きで記録
- `ChatRoomStore`: カード投稿・スキップ・生成完了（summary 文字数 / 訂正件数 / フレーズ件数）・
  失敗・リトライを記録する
- 上限は 1 回の生成で数 KB に収める（診断ログ全体は 256KB でローリング）
- **完了条件**: シミュレータで 1 セッション回して、開始 → SSE 完了 → 生テキスト → 完了 が
  時系列で残ること

#### 実装結果（2026-07-27）✅

- 追加した行（すべて `DiagnosticsLog`。管理画面 📊 →「診断」タブで読める）
  - `!! sse: data 行を解釈できず破棄 len=… body=…` / `!! sse: error イベント type=… …`
  - `feedback: 生成開始 topic=… transcript=…字/…行`
  - `!! feedback: HTTP <code> …` / `!! feedback: HTTP 応答が不正`
  - `feedback: SSE 完了 stop=… deltas=… text=…字 in=… out=…`
  - `feedback: 生の出力 <JSON 全文・4000 字で中略>`
  - `!! feedback: 応答を解釈できず失敗 …` / `feedback: 解釈 OK summary=…字 corrections=… phrases=…`
  - `feedback: カード投稿 発話=…件 transcript=…字` / `発話 N 件のためスキップ` / `リトライ` /
    `!! Anthropic API キーが未設定` / `!! 生成に失敗 …` / `カードへ反映 summary=…`
- ログ本文は `DiagnosticsSnippet.make(_:limit:)` を通す（`Support/DiagnosticsLog.swift`）。
  **改行系（LF/CR/VT/FF/NEL/LS/PS）を可視化する** —— ログを 1 行に保つためだけでなく、
  これらが生の応答に混ざっていること自体が H1 の証拠になるため
- 挙動は変えていない（壊れた `data:` 行は従来どおり捨てる = H1 なら破棄ログの直後に欠落が出る）
- 確認: ユニットテスト 176 件パス（`DiagnosticsSnippetTests` 6 件 + 壊れた data 行の回帰 1 件を追加）。
  シミュレータで `-start-conversation -send-text …×2`（2 発話 + goodbye）を回し、
  カード投稿 → 生成開始 → SSE 完了（`stop=end_turn deltas=15 text=825字`）→ 生の出力（JSON 全文）→
  解釈 OK → カードへ反映 が時系列で残ることを確認した。途切れは再現せず（想定どおり）
- 副産物: トピック候補生成が `overloaded_error` で失敗していたのが
  `!! sse: error イベント type=overloaded_error Overloaded` として初めて可視化された
  （従来は握りつぶし。同じ SSE パーサを通る全クライアントに効く）

### Phase 2: 再現待ちと原因確定

- 次に途切れが起きたら「診断」タブの全文を回収する
- 判定表
  | ログの状態 | 確定する仮説 |
  | --- | --- |
  | `!! sse: data 行を解釈できず破棄` がある | H1 |
  | 生テキストの時点で途切れている / `stop=max_tokens` | H3 or H4 |
  | `stop=-`（message_delta なし）で text が短い | H2 |
  | 生テキストは完全なのに表示が途切れている | 表示・保存側（別途調査） |
- **完了条件**: 原因が 1 つに特定され、途切れる条件がコードで説明できる

### Phase 3: 対策

原因確定後に確定させる。原因に関わらず入れておく価値がある防御（要検討）:

- `ClaudeSSE` を **行単位ではなくバイト列のバッファリング**に変える
  （`bytes.lines` をやめ、`\n` だけで区切る自前のスプリッタにする）。
  H1 が原因ならこれが本命の修正で、**会話ターン側の欠落も同時に直る**
- デコードできなかった `data:` 行を捨てずに、次の行と連結してもう一度試す（保守的な代替案）
- `stop_reason` が `end_turn` 以外（`max_tokens` 等）ならデコードが通ってもエラー扱いにする

### Phase 4: テスト・確認・後片付け

- ユニットテストを追加する（`EslSpeakingCoachTests/`）
  - 分割された `data:` 行を与えたときに欠落しないこと（Phase 3 の実装に対して）
  - `stop_reason` 異常系の扱い
- シミュレータで 1 セッション回してログの体裁を確認、実機で再発しないことを確認する
- 仕様書（`docs/specs/session-feedback.md`）に必要なら反映し、
  本プランを `docs/plans/archive/` へ移動、TODO を DONE へ

## 影響範囲

- `EslSpeakingCoach/Claude/ClaudeMessagesClient.swift`（`ClaudeSSE.parse` のログ / Phase 3 の分割対応）
- `EslSpeakingCoach/Claude/SessionFeedbackClient.swift`（生成前後のログ）
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift`（カード投稿・完了・失敗のログ）
- `EslSpeakingCoach/Support/DiagnosticsLog.swift`（既存。変更なしで相乗り）

## テスト方針

- Phase 1 のログは挙動を変えないので、既存 169 件が通ることを回帰の確認とする
- ログ本文の組み立て（上限付きスニペット）は純関数として切り出してユニットテストする
- 実際の途切れは再現手段が無いため、**再現待ち**（Phase 2）を前提にする
