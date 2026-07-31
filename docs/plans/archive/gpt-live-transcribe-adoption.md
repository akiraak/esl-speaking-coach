# gpt-live-transcribe への対応（クライアント側発話終端検知 + 手動 commit）

2026-07-31 作成。検証（`archive/gpt-live-transcribe-verification.md`）と調査（`archive/client-side-endpointing.md`）の後続タスク。

## 進捗（2026-07-31）

- **Phase 1 完了**: `Voice/ClientSpeechEndpointer.swift`（純粋な値型の状態機械）+ ユニットテスト 12 件。
  判定はバッファ数ではなく実時間で数える（HFP 等でサンプルレートが変わっても基準を保つため、
  `record(level:duration:noiseFloor:)` にバッファの実時間を渡す）。閾値は
  `min(max(floor × snrRatio, minimumPeak), unconditionalPeak)` の 1 本
  （unconditionalPeak は「フロア推定が不当に高くても拾う」保険を閾値の上限として表現）。
  暗騒音は `SegmentLevelMeter.currentNoiseFloor`（新設の読み出し口）を共有し二重推定しない
- **Phase 2 完了**: `AudioTapRouter` に送信ゲート（`attachGatedPCM16` / `GatedMicEvent` /
  `resetSpeechGate`）、`OpenAITranscriptionStream` に `noteClientSpeechStarted` /
  `commitClientSegment`（commit は sendQueue 経由で append との順序保証）、
  `TurnBasedVoiceSession` は `isLiveTranscribe` でストリームの受け方だけ分岐。
  音声と発話境界を 1 本の `GatedMicEvent` ストリームで運ぶことで「append 完了後に commit」を
  ストリーム順序そのままで保証。`input_audio_buffer` 系のサーバエラー（空 commit 等）は
  ignorable 扱いにしてセッションを殺さない。ユニットテスト追加（ゲート開閉 4 件 + JSON 2 件）
- **Phase 3 完了**: シミュレータは live 指定（`-stt-model gpt-live-transcribe -start-conversation
  -send-text ...`）で ready 到達 + テキスト会話回帰 OK、4o 既定の通常起動回帰 OK、
  全ユニットテスト 298 件パス。実機検証（精度・終端の体感・barge-in・課金）もユーザー実施で完了
- **Phase 4 完了（2026-07-31 採用）**: 実機検証の結果を受けて既定を切替。
  `OpenAITranscriptionConfiguration.model` = `gpt-live-transcribe`、`delay` は検証の基準にした
  `low` をサーバ既定任せにせず明示固定。旧経路（`gpt-4o-transcribe` + サーバ VAD）は削除せず、
  `-stt-model gpt-4o-transcribe` か既定値 1 箇所でいつでも戻せる。`CLAUDE.md`（技術スタック・
  音声レイヤの方針・経緯）と `docs/specs/ai-cost-map.md`（課金マップ・単価表・概算例）を更新。
  live で長期安定した時点で旧経路の掃除タスクを別途起こす

## 目的・背景

- OpenAI の新 STT `gpt-live-transcribe` は現行 `gpt-4o-transcribe` より認識精度が良い（公称 + 簡易実測）が、**サーバ VAD 非対応**のため、発話終端・barge-in の検知をクライアントで行い `input_audio_buffer.commit` を送る実装が必要
- 成立条件は実測済み: 発話区間だけ append → commit すれば課金も発話ぶんだけ（セグメントごと秒単位切り上げ・$0.017/分）。commit → completed は約 0.7 秒
- 発話終端の判定材料（43ms 刻み RMS・暗騒音の移動中央値・0.5 秒の遡りバッファ・読み上げ中のフロア更新停止）は `AudioTapRouter` / `SegmentLevelMeter` に既にあり、足りないのは状態機械だけ

## 対応方針

**旧モデルの経路は消さず、live のときだけクライアント VAD + 手動 commit を使う「横に並べる」構成にする。** 既定モデルの切替は最後の Phase で判断し、いつでも `gpt-4o-transcribe` に戻せる状態を維持する。

### Phase 1: `ClientSpeechEndpointer`（クライアント VAD の状態機械）

- 新規 `Voice/ClientSpeechEndpointer.swift`。タップバッファごとの RMS（43ms 刻み）を入力に、`speechStarted` / `speechStopped` を出力する**純粋な値型の状態機械**にする（`SegmentLevelMeter` と同じ流儀。オーディオスレッド駆動なのでロック下で使える形）
- 判定パラメータ（`Thresholds` として調整可能に）:
  - 開始: `max(暗騒音 × snrRatio, minimumPeak)` を **N バッファ連続**で超えたら発話開始（単発の物音で発火しない）。`SpeechLevelGate.Thresholds` の実機調整値（snrRatio 3.0 / minimumPeak 0.01 / unconditionalPeak 0.05）を初期値に流用する
  - 終端: 閾値未満が **800ms 継続**（現行のサーバ VAD `silence_duration_ms` と同値）で発話終端
  - 遡り: 開始判定時に直近 0.5 秒（`lookbackWindow` 相当）を prefix padding としてセグメントに含める
  - フェイルセーフ: 発話開始から `maxSegmentDuration`（初期値 60 秒）で**強制終端**する。エネルギー VAD は持続的な環境音（テレビ等）で終端が出ないことがあり、その場合 append と課金が無制限に伸びる（サーバ VAD 時代には無かった故障モード）
- 暗騒音の推定・読み上げ中の更新停止は `SegmentLevelMeter` の実装を共有（二重推定しない形に整理する）
- **テスト**: 合成レベル系列 → イベント列の純関数ユニットテスト（開始の連続条件 / 800ms 終端 / 物音単発で発火しない / 静かな部屋でフロア 0 のときの絶対値フォールバック / 読み上げ中の抑制 / `maxSegmentDuration` 到達で強制終端）

### Phase 2: live 用の送信ゲートと commit の組み込み

- `AudioTapRouter` に「エンドポインタ駆動 + 遡りリングバッファ付きの送信ゲート」モードを追加: live のときは PCM を常時 STT へ流すのではなく、**発話開始判定〜終端判定 + 遡り 0.5 秒ぶんだけ** append し、終端で `input_audio_buffer.commit` を送る（無音・AI 発話中は送らない = 課金しない）
- `OpenAITranscriptionStream` に commit 送信を追加（`sendQueue` 経由で順序保証）。live では `speechStarted` / `speechStopped` をサーバイベントからではなくエンドポインタから `STTStreamEvent` に流す
- `TurnBasedVoiceSession` は**イベントの発生源が変わるだけ**で状態遷移・barge-in・`SpeechLevelGate`・メトリクスは現状維持。4o のときは今までどおりサーバ VAD イベントを使う
- 注意点:
  - completed は commit への応答としてしか届かない（約 0.7 秒）。メトリクスの「STT確定」がそのぶん伸びるので、`TurnMetricsBuilder` の計測点はそのまま比較できるようにする
  - セグメント間で認識文脈は引き継がれないため、遡りパディングの欠けは精度に直撃する（Phase 1 の lookback を必ず通す）
  - barge-in はクライアント判定になる。読み上げ中は Voice Processing + フロア更新停止が前提（現行と同じ）
  - 再接続時、送信中セグメントの append 済み音声はサーバ側で失われる（新しい接続のバッファは空なので `input_audio_buffer.clear` は不要）。**エンドポインタと送信ゲートを idle にリセットしてセグメントを破棄**し、言い直してもらう。現行のサーバ VAD でも切断時のセグメントは失われるため挙動として同等。セグメント PCM をローカル保持して再 append する案は複雑化に見合わないので、採用後の改善候補に留める
- **テスト**: commit / append の JSON とゲート開閉のユニットテスト。4o 経路が不変であることは既存の `sessionUpdate` GA 形テストで担保

### Phase 3: シミュレータ E2E + 実機検証

- シミュレータ: `-stt-model gpt-live-transcribe -start-conversation` で ready 到達・テキスト入力での会話回帰（マイク無効のため音声パスは対象外）。4o 既定のフル回帰（全テスト + 通常起動）
- 実機（ユーザー）: `./run-install-iphone.sh -stt-model gpt-live-transcribe [-stt-delay low]` で比較
  - 認識精度（短い発話・雑音・prompt エコー幻覚の再現有無）
  - 終端の体感（自前 VAD の切りどころ。ささやき声・考え込み中の間で早切れしないか）
  - barge-in の反応
  - 課金実測（管理画面の料金タブと OpenAI ダッシュボードの突き合わせ。「発話ぶんだけ」になっているか）
  - `delay` は low を基準に medium も試す（終端レイテンシと精度のトレードオフ）

### Phase 4: 採用判断と既定切替

- Phase 3 の結果で採用可否を判断する。判断基準:
  - **コスト**: 発話分あたり約 3 倍（$0.017/分 vs 現行約 $0.006/分）の増加に、認識精度の改善（短い発話の言語誤判定・prompt エコー幻覚・雑音誤認識の解消度合い）が見合うか
  - **レイテンシ**: ターン確定が約 +0.7 秒遅くなる（commit → completed 待ち）体感悪化が許容できるか
  - **終端品質**: 自前 VAD の切りどころ（早切れ・切れ残り）が実用レベルか
- 採用なら `OpenAITranscriptionConfiguration.model` の既定値を切替え、`CLAUDE.md`（音声レイヤの方針の表・不採用リスト）と `docs/specs/ai-cost-map.md` を更新
- **旧経路（4o + サーバ VAD）は削除しない**。既定値 1 箇所でいつでも戻せる状態を維持し、live で長期安定した時点で掃除タスクを別途起こす
- 見送りなら本プランに理由を記録してアーカイブ（切替スイッチと Phase 1〜2 の実装は DEBUG 検証用に残すか、そのとき判断）

## 影響範囲

- 変更は `Voice/` 配下中心: `ClientSpeechEndpointer.swift`（新規）/ `MicrophoneCapture.swift`（AudioTapRouter のゲート）/ `OpenAITranscriptionStream.swift`（commit・イベント源の分岐）/ `TurnBasedVoiceSession.swift`（配線）
- **Phase 4 まで既定動作は一切変わらない**（live 経路は `-stt-model` 起動引数のときだけ通る）
- 保存データ・会話履歴・料金記録はモデル非依存（料金計算は実装済み）。UI・練習モード・クイズには影響しない

## テスト方針

- ユニット: エンドポインタの状態機械（合成レベル系列）、送信ゲート、commit の JSON、4o 経路の不変（既存テスト）
- シミュレータ: live 接続の ready 到達・テキスト会話回帰・4o フル回帰
- 実機: 精度・終端の体感・barge-in・課金実測（Phase 3。ユーザー実施）
