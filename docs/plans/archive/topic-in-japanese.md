# トピックを日本語で作成

## 目的・背景

トピックカードの候補（title / hook）は現在英語で生成している。学習者（日本人）がカードを一目で理解して選べるよう、トピック候補を日本語で生成・表示する。会話そのものは従来どおり英語のみ。

## 対応方針

1. `TopicSuggestionClient.systemPrompt` を変更し、title / hook を自然な日本語で生成させる
   - title: カードラベルとして機能する短い日本語（おおむね 4〜10 文字程度の体言止め〜短句）
   - hook: 誘い文句 1 文（短い日本語の問いかけ or ティザー）
   - 生成ルール（日常寄り・3 件のバリエーション・recent-topics との重複回避）は維持
2. 会話へのトピックの渡し方は変えない（`[New topic: <タイトル>]`）。タイトルが日本語になるため、`CoachSystemPrompt` の App control messages 節に「topic 名は日本語で書かれることがあるが、会話は常に英語。トピックは英語で自然に開く」旨を 1 文追記する
3. アプリ側固定候補 `freeTalkCandidate` を日本語化（「フリートーク」+ 日本語 hook）
4. 自作トピック入力アラートの placeholder 例文を日本語に変更（`ChatRoomView`）
5. 仕様書 `docs/specs/conversation-design.md` 付録 B の system prompt を実装に合わせて更新

## 影響範囲

- `EslSpeakingCoach/Claude/TopicSuggestionClient.swift`（system prompt 文言のみ。リクエスト構造・スキーマは不変）
- `EslSpeakingCoach/Claude/CoachSystemPrompt.swift`（1 文追記。プレフィックスが変わるため既存キャッシュは一度無効化されるが、固定文のままなので以降は再キャッシュされる）
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift`（freeTalkCandidate の文言）
- `EslSpeakingCoach/Conversation/ChatRoomView.swift`（placeholder 文言）
- 履歴・フィードバック（`topicTitle` を表示・送信する箇所）は日本語文字列でもそのまま動くため変更なし

## テスト方針

- 既存の `TopicSuggestionClientTests` は言語非依存（リクエスト構造の規約チェック）のためそのまま通ることを確認
- `xcodebuild build` + ユニットテストの実行
- シミュレータで起動し、トピックカードに日本語候補 3 件 + フリートークが表示され、選択すると英語で会話が始まることを確認
