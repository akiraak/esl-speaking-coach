# キャラごとの記憶（Chobi / Naruko 自身の記憶）

## 目的・背景

現在の記憶ノート（`CharacterMemoryRecord`。[character-memory.md](archive/character-memory.md)）は **1 本**で、中身は「学習者について」「直近セッション要約」の 2 部だけ。キャラ自身の身の上は system prompt の固定文（Chobi = 猫 / コーヒー / ミステリ小説、Naruko = ラーメン / カラオケ / ソシャゲ）しかなく、**会話中にキャラが自分について話したことはセッションが終わると消える**。

- 学習者のことは覚えているのに、キャラは自分のことを覚えていないという非対称。「先週拾った子猫」の話をしても、次のセッションでは無かったことになる
- 「発話量を稼ぐ」第一目的にも効く。キャラ側に近況があると学習者から質問が出る（"How's your cat?"）し、キャラの話題提供が固定プロフィール 3 語の使い回しから抜けられる

## 決定事項（2026-08-05）

- **キャラごとに別ノートを持つ**（Chobi 用 / Naruko 用）。注入・管理画面・リセットも 2 本立てにする
- **学習者ノートは共有のまま残す**（合計 3 本: shared / chobi / naruko）。学習者の事実は 2 人が同席して聞いている以上キャラ間で分ける意味がなく、二重化はトークンと内容の乖離を生むだけ。分かれるのは「自分自身のこと」

## 対応方針

### 記憶の構成（3 本）

| scope | 内容 | 注入の形 | 語数の目安 |
| --- | --- | --- | --- |
| `shared`（既存レコードを流用） | 学習者の事実 + 直近セッション要約（現行のまま） | `[Memory: ...]` | 400 語以内（現状維持） |
| `chobi` | Chobi 自身のこと: 会話で話した身の上・出来事・学習者とした約束・2 人の定番ネタ | `[Memory about Chobi: ...]` | 120 語以内 |
| `naruko` | 同上（Naruko 自身） | `[Memory about Naruko: ...]` | 120 語以内 |

- **キャラのノートは両方注入する**。2 人は同席していて互いの話も聞いているので、片方だけ渡すと相手の近況に相槌が打てない。「自分のノート = 自分に起きたこと」「相手のノート = 前に聞いて知っていること」の区別は system prompt で付ける
- ノートに書くのは**会話に実際に出た自分の話だけ**。system prompt の固定プロフィール（猫・ラーメン等）は書き写さない（二重管理になり、ノートが太るだけで情報が増えない）

### 生成 — 1 回の呼び出しで 3 本

`MemoryUpdateClient` の structured outputs を `{"memory": string}` → `{"learner": string, "chobi": string, "naruko": string}` に拡張し、**セッション終了時 1 回の呼び出しのまま 3 本を同時に更新**する。

- 3 回に分けない理由: transcript を 3 回送ることになり入力が 3 倍、プロンプトキャッシュも 3 回ぶん、しかも 3 本が互いに矛盾しうる（誰の発言かの解釈が呼び出しごとにぶれる）
- **振り分けは transcript の話者タグ基準**。`Chobi:` 行の自分語りは chobi ノート、`Naruko:` 行は naruko ノートへ。相手について観察したことを相手のノートに書かない（本人の発言が正）
- キャラのノートが空（今回そのキャラが自分の話をしなかった）なら**前回のノートを維持**する（空文字で上書きしない）。学習者ノートが空のときは現行どおり `malformedContent` 扱いで全体を捨てる
- 失敗は best effort（3 本とも前回のまま残る）。冪等性は現行と同じ
- `max_tokens` は 2000 → 2500 へ（出力が 3 本ぶんになるため）。effort・モデル選択（`ClaudeRoute.memoryUpdate`）は変えない

### 保存 — scope 付きレコード

- `CharacterMemoryRecord` に `scopeRawValue: String?` を足す。**nil = shared** とし、既存レコードはそのまま学習者ノートとして生きる（SwiftData のライトウェイトマイグレーション。`ChatSessionRecord.modeRawValue` の nil = conversation と同じ手口）
- `MemoryScope` enum（`shared` / `chobi` / `naruko`）を新設。キャラ 2 値は `ChatCharacter` から導出して定義を二重に持たない
- `CharacterMemoryStore` の API を scope 付きに広げる: `currentNote(_:)` / `snapshot(_:)` / `save(text:scope:sourceSessionID:)` / `reset(_:)` / `resetAll()`。各 scope は引き続き**単一レコードを上書き**する
- 3 本を 1 度に書く `saveAll(learner:chobi:naruko:sourceSessionID:)` を足す（部分保存で組み合わせがずれない）

### 注入

- `TurnBasedVoiceSession.Configuration.memoryNote: String?` を `memoryNotes: MemoryNotes`（learner / chobi / naruko の 3 フィールドを持つ値型。全部 nil が「記憶なし」）へ置き換える
- `SessionOpeningMessage.compose` / `composeMemoryOnly` が 3 ブロックを改行で連結して**先頭 user メッセージ 1 通**にまとめる。空のノートは行ごと省略し、全部空なら現行どおり何も積まない

  ```
  [Memory: <学習者ノート>]
  [Memory about Chobi: <Chobi ノート>]
  [Memory about Naruko: <Naruko ノート>]
  [New topic: X]
  ```

- 学習者開始（`learnerFirst`）では `[New topic:]` 行が無いだけで形は同じ。第一声は現行どおり `appendUserMessage` で同じ user メッセージへ結合される
- `ChatRoomStore.rebuildHistory`（エラー再開）も同じ合成を使う
- 単語・クイズは現行どおり注入も更新もしない（`SessionKind.usesMemoryNote` の 1 か所で止まる）

### system prompt

`CoachSystemPrompt` の App control messages 節に `[Memory about Chobi: ...]` / `[Memory about Naruko: ...]` の扱いを追記する。

- 自分のノートは**自分に実際に起きたこと**として扱う。相手のノートは前に聞いて知っていること
- 固定プロフィールと矛盾したらノートを優先する（あとから起きたこと）。学習者の発言と矛盾したら学習者を優先する（現行ルールのまま）
- 近況を自分から長く語らない。会話が触れたときに一言添えるか、学習者への質問の足場に使う（現行の "never makes the conversation about herself for long" を維持）
- 括弧書きは読み上げない・引用しない・複数の記憶を並べない（現行の `[Memory: ...]` と同じ）

追記は**一度きりのキャッシュ invalidation**で、以後は新しい固定文でキャッシュが効く。`docs/specs/conversation-design.md` 付録 A も同期する。

### 管理画面

- 「記憶」タブの先頭に Picker（学習者 / Chobi / Naruko）を置き、選択中のノート本文・更新日時・**そのノートだけのリセット**を出す
- 「すべての記憶をリセット」も残す
- footer で挙動を明示する（例: 「Chobi の記憶だけ消すと、学習者のことは覚えたまま Chobi 自身の身の上が白紙になります」）

### コスト影響

- **生成**: 呼び出しは 1 回 / セッションのまま。出力が 3 本ぶんに増える（+1k トークン未満）
- **会話ターン**: 先頭 user メッセージが最大 +240 語（≈ 320 トークン）。記憶は messages 側でキャッシュ対象外なので毎ターン乗る。20 ターンで ≈ 6.4k トークン ≈ $0.02（sonnet-5 入力 $3/Mtok）。キャラノートを 120 語で頭打ちにしてこの範囲へ収める
- `docs/specs/ai-cost-map.md` の 6 番（記憶ノート更新）を 3 本構成に更新する

### リスク・注意

| リスク | 対処 |
| --- | --- |
| 台本 LLM が Chobi のノートに Naruko の出来事を混ぜる | 生成プロンプトで話者タグ基準を明示。E2E で 3 本の中身を目視確認 |
| ノートが固定プロフィールと矛盾（猫が犬になる） | 「ノート優先・ただし捏造禁止」を生成側と system prompt の両方に書く |
| ノートが太って毎ターンのコストが効いてくる | 語数上限をプロンプトで指示し、管理画面で実際の長さを見て詰める |
| 既存レコードのマイグレーション失敗 | 追加は optional プロパティ 1 つのみ（nil = shared）。実機の既存ストアで開けることを確認する |

### スコープ外

- セッション間の経過時間でキャラの近況を自動生成する（人生を進行させる）— 別タスク
- 学習者ノートをキャラごとに分ける（誰が何を覚えているか）— 上記の理由で採らない
- 単語・クイズセッションでの記憶の注入・更新
- トピック提案への記憶の活用（`character-memory.md` の時点からスコープ外のまま）

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Persistence/CharacterMemoryStore.swift` | `MemoryScope` 追加 / `CharacterMemoryRecord.scopeRawValue` / scope 付き API / `saveAll` / `resetAll` |
| `Claude/MemoryUpdateClient.swift` | structured outputs 3 フィールド化 / 振り分けと語数のプロンプト追記 / `parseResult` の戻りを 3 本に / `max_tokens` 2500 |
| `Conversation/ChatRoomStore.swift` | 開始時に 3 本読み込み / `MemoryNotes` の受け渡し / 終了時に `saveAll` / `rebuildHistory` |
| `Conversation/ConversationModels.swift` | `SessionOpeningMessage` の 3 ブロック合成 / `MemoryNotes` 値型 |
| `Voice/TurnBasedVoiceSession.swift` | `Configuration.memoryNote` → `memoryNotes` |
| `Claude/CoachSystemPrompt.swift` | App control messages 節に 2 行の記憶メッセージの扱いを追記 |
| `Admin/MemoryAdminView.swift` | scope Picker / 個別リセット / 全リセット |
| `docs/specs/conversation-design.md` | 付録 A（system prompt 全文）と記憶の渡し方を同期 |
| `docs/specs/ai-cost-map.md` | 6 番を 3 本構成へ更新 |

## テスト方針

- `MemoryUpdateClientTests`: 3 フィールドの schema / `parseResult`（正常・キャラ空は前回維持・学習者空は malformed・refusal・壊れた JSON）
- `CharacterMemoryStoreTests`: scope 別の保存と上書き / 個別リセットが他 scope を消さない / 全リセット / **`scopeRawValue` が nil の既存レコードが shared として読めること**
- `SessionOpeningMessage`: 3 本あり / 一部空 / 全部空 / 単語・クイズでは混ざらない
- `AdminViewTests`: 既存の Tab 網羅テストを壊さない
- `xcodebuild` でビルド + 単体テスト全件パス
- シミュレータ E2E: `-start-conversation -send-text ...` で 2 セッション通し。1 回目でキャラに自分の話をさせ（"Chobi, do you have any pets?"）、終了後に管理画面で 3 本に分かれて保存されていることを確認。2 回目で "How's your cat?" に Chobi が前回の内容で答え、Naruko が相手の話として受けられることを確認
- 実機で 1 通し（記憶の引き継ぎと、近況を語りすぎていないこと）

## Phase / Step

- [x] Phase 1: 保存（`MemoryScope` + `scopeRawValue` + scope 付きストア API + 既存レコードのマイグレーション確認）2026-08-05
- [x] Phase 2: 生成（3 フィールド structured outputs + 振り分け / 語数プロンプト + `saveAll`）2026-08-05
- [x] Phase 3: 注入（`MemoryNotes` + 3 ブロック合成 + `rebuildHistory` + system prompt 追記 + spec 同期）2026-08-05
- [x] Phase 4: 管理画面（scope Picker + 個別リセット / 全リセット）2026-08-05
- [x] Phase 5: シミュレータ E2E + 実機確認 + ドキュメント同期（ai-cost-map.md / conversation-design.md）2026-08-05

## 実装結果（2026-08-05）

プラン通り。差分は以下だけ。

- `MemoryUpdateClient.parseResult` の戻りは専用の値型 `MemoryUpdateClient.UpdatedNotes`（learner は非 optional、キャラは nil = 前回維持）。注入側の `MemoryNotes` とは別型にして「生成の出力」と「注入の入力」を混ぜない
- 管理画面のサマリ（項目一覧の「記憶」行）は `snapshot()?.updatedAt` から `latestUpdatedAt()`（3 本の最新）へ。学習者ノートだけ個別リセットしても「未保存」にならないように
- 診断ログに `memory: 更新 learner=N字 chobi=N字 naruko=N字` を 1 行足した（実機で 3 本に分かれて書けたかを確認するため。`前回維持` も出る）

### シミュレータ E2E の結果

2 セッション通し（`-start-conversation -send-text ...`）。

1 回目（"Chobi, do you have any pets at home right now?" / "Naruko, what did you do last weekend?"）の終了後、SwiftData に 3 レコード。**既存の 1 本ノート（`scopeRawValue` が nil の Z_PK=1）はそのまま学習者ノートとして上書きされ**、chobi / naruko が新規に増えた（マイグレーション確認）。

```
scope=(nil=shared)  About the learner / - Name is Akira, works as a software engineer in Tokyo. …
scope=chobi         - Has two cats at home that keep her busy.
scope=naruko        - Went to karaoke with a friend last weekend, followed by ramen.
```

2 回目（"Chobi, how are your cats doing today?" / "Naruko, did Chobi ever tell you about her cats?"）で狙いどおりの引き継ぎになった。

```
user:   Hello again! Chobi, how are your cats doing today?
chobi:  My cats are doing great, thank you for asking, Akira! They were extra playful this morning, actually.
chobi:  So, how has your week been going so far?
user:   Naruko, did Chobi ever tell you about her cats? And how was your karaoke?
naruko: Yeah, she talks about them sometimes, they sound so cute! My karaoke was so much fun, I sang way too many songs.
naruko: What kind of songs do you like to sing, Akira?
```

- Chobi は自分のノートを「自分に起きたこと」として答え、Naruko は相手のノートを「前に聞いて知っていること」として受けた（"she talks about them sometimes"）
- 近況は 1 行で、どのターンも最終行が学習者への質問（語りすぎていない）
- 2 回目終了後もノートは scope をまたがず更新され、レコードは 3 本のまま（学習者ノートは最古のセッション要約を 1 行落として長さを保った）

### 実機確認

2026-08-05。記憶の引き継ぎ・近況を語りすぎないことともに問題なし。これで確定。
