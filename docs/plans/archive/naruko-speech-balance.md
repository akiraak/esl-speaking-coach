# Naruko の発話量が少ない問題のバランス調整

## 目的・背景

実会話で Naruko の発話が Chobi に比べて明らかに少ない。原因は会話 system prompt（`CoachSystemPrompt` = conversation-design.md 付録 A）の 2 点:

1. Naruko のキャラ設定に **"Speaks less than Chobi."** と明記している
2. 通常ターンは「たいてい 1 キャラのみ発話」で、ホール役の Chobi がターンを取り最終行の質問も出す、というバイアスが働く（誰が質問してよいかの指定もない）

## 対応方針

system prompt を最小限の文言変更でリバランスする（キャラ性・短いターン・学習者が最も話す、の原則は維持）:

- Naruko のキャラ設定: "Speaks less than Chobi" を撤廃し、「頻度は Chobi と同程度、ただし話し方が違う（短いリアクションと素朴な質問）」へ
- Output format: セッション全体で両キャラのターン取得を同程度にする・最終行の質問はどちらが出してもよい（Naruko も同程度に出す）・Chobi の連続ターンを避ける、を明記
- トピック開始ターン: どちらのキャラが口火を切るかをトピックごとに変える
- conversation-design.md（キャラ表・ターン進行・付録 A・変更履歴）を同期

プロンプトキャッシュの制約（最小プレフィックス 1024 トークン）は文言追加方向なので維持される。可変要素は入れない。

## 影響範囲

- `EslSpeakingCoach/Claude/CoachSystemPrompt.swift`
- `docs/specs/conversation-design.md`
- コードロジック・API パラメータの変更なし

## テスト方針

- ビルド + 既存単体テストのパス（prompt 内容に依存するテストは無いことを確認済み）
- 発話バランスの実際の改善は実会話（実機）で確認する。実機未確認の旨を DONE に明記
