# クライアント側の発話終端（ターン終了）検知の調査

2026-07-31 作成。gpt-live-transcribe 検証（`archive/gpt-live-transcribe-verification.md`）の帰結タスク。

## 目的・背景

- gpt-live-transcribe はサーバ VAD 非対応（手動 `input_audio_buffer.commit` のみ）。採用するには**「ユーザーが話し終わった」をアプリ側で検知して commit を送る**実装が必要
- 現行パイプラインはサーバ VAD に 3 つの役割を負わせている: ①発話開始検知（barge-in の起点）②発話終端検知（ターン確定の起点）③セグメント切り出し。この 3 つをクライアントで置き換えられるかを調べる
- この調査は**実装しない**。選択肢の比較・既存部品の流用可否・推奨案をまとめるところまで

## 調査項目

1. アプリ内の既存部品で何が流用できるか（`AudioTapRouter` / `SegmentLevelMeter` / `SpeechLevelGate` の RMS・暗騒音推定）
2. iOS で使えるクライアント VAD の選択肢（自前エネルギー VAD / Apple のフレームワーク / Silero VAD / WebRTC VAD）
3. gpt-live-transcribe 側の制約との噛み合わせ（commit 単位・`input_audio_buffer.clear` の可否・課金範囲・delta をシグナルに使えるか）
4. 統合ポイント（`TurnBasedVoiceSession` の状態遷移・barge-in・読み上げ中の回り込み対策との整合）

## テスト方針（調査の検証手段）

- API 仕様の不明点（segment ごとの commit・clear・課金の数え方）は probe スクリプトで実測する
- ライブラリ候補はライセンス・依存の重さ・iOS 実績を文献ベースで確認する（ビルドまではしない）

## 調査結果（2026-07-31）

### 結論（推奨案）

**まず自前のエネルギー VAD（案 A）で作り、精度が足りなければ学習済み VAD（案 B）に差し替える** 2 段構えを推奨する。判定部を小さなプロトコル境界に切っておけば差し替えは局所で済む。

- **案 A: 自前エネルギー VAD（推奨・追加依存ゼロ）**
  既存の `AudioTapRouter` / `SegmentLevelMeter` が持つ「43ms 刻みの RMS + 暗騒音の移動中央値 + 0.5 秒の遡りバッファ + 読み上げ中のフロア更新停止」は、エネルギー VAD の材料そのもの。足りないのは**状態機械だけ**（開始 = 閾値超えが N バッファ連続、終端 = 閾値未満が 800ms 継続）。閾値の思想（暗騒音×比・絶対値の下限）は `SpeechLevelGate` で実機調整済みのものを流用できる
- **案 B-1: Apple 純正 `SpeechDetector`（iOS 26+）**
  Speech フレームワークの VAD モジュール。`SpeechAnalyzer` に組み込み、`speechDetected: Bool` + 時刻範囲の AsyncSequence を返す。感度は low / medium / high の 3 段階。OS 純正・依存ゼロが利点だが、SpeechAnalyzer 経由の組み込みになる点と、**アセット（モデル DL）要否・シミュレータ動作が未確認**（採用時に 30 分のスパイクで `AssetInventory.status(forModules:)` を見る）
- **案 B-2: Silero VAD（CoreML / ONNX ポート）**
  約 309K パラメータの学習済み VAD（32ms @16kHz 刻みで発話確率を返す）。雑音下の精度はエネルギー VAD より明確に上。CoreML 変換済みモデル（FluidInference/silero-vad-coreml）や Swift SDK（FluidAudio 等）が既にある。パッケージ依存とモデル同梱が増えるのが難点

### gpt-live-transcribe 側の成立条件（probe で実測済み）

「クライアント VAD が切り出した発話区間だけ送って commit」する設計が成立することを確認した:

- **append → commit の繰り返しが 1 セッションでできる**（セグメントごとに completed + usage が届く）
- **送らなければ課金されない**: usage は commit した音声の長さ（セグメントごと秒単位切り上げ。2.09 秒 → 3 秒）。発話区間だけ送れば現行同様「話した時間だけ課金」にできる。ただし切り上げが commit ごとに乗るので、細切れ commit はコスト効率が悪い
- `input_audio_buffer.clear` も受理される（仕切り直しに使える）
- **commit → completed は実測 0.7 秒前後**。現行（`speech_stopped` → 確定ほぼ 0ms）よりターン確定が +0.7 秒程度遅くなる見込み。delta で本文の大半は先に届くが、末尾の語は commit まで保留されるため completed 待ちは必須
- **セグメントをまたぐ文脈は引き継がれない**（語の途中で切った 2 個目の認識が乱れた）。切り出し位置の品質がそのまま精度に効くため、遡り 0.5 秒の prefix padding は必須

### 実装した場合の構成イメージ

1. **`ClientSpeechEndpointer`（新規）**: `AudioTapRouter` の RMS ストリームを入力とする状態機械。`speechStarted` / `speechStopped` 相当のイベントを発行する
2. **送信ゲート**: マイクタップは常時回すが、STT への append は「発話開始判定〜終端判定 + 遡り 0.5 秒」だけ。終端で commit
3. **`TurnBasedVoiceSession` はほぼ現状維持**: `.speechStarted` / `.speechStopped` の発生源がサーバ VAD からクライアント VAD に変わるだけで、状態遷移・barge-in・レベルゲート・メトリクスの形は保てる
4. **barge-in**: 現行どおり Voice Processing（エコーキャンセル）+ 読み上げ中のフロア更新停止で対応。クライアント判定になるぶんサーバ往復が無くなり、むしろ速くなる

### リスク・未解決

- エネルギー VAD の弱点: ささやき声・小声で終端が早まる / 持続的な環境音（テレビ等）で終端が出にくい。実機での閾値調整が必須（`SpeechLevelGate` のときと同じ進め方）
- `SpeechDetector` のアセット要否・シミュレータ動作は未確認
- `delay` 設定（minimal〜xhigh）と commit → completed レイテンシの関係は low しか実測していない

### 参考

- probe スクリプト: セッション設定の総当たり・セグメント分割 commit の実測（scratchpad。要点は本ドキュメントに転記済み）
- [Silero VAD CoreML 変換モデル](https://huggingface.co/FluidInference/silero-vad-coreml) / [FluidAudio SDK](https://cocoapods.org/pods/FluidAudio) / [RealTimeCutVADLibrary（ONNX + WebRTC APM）](https://github.com/helloooideeeeea/RealTimeCutVADLibrary)
- [Apple SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)（API 形状は Xcode 26.5 SDK の swiftinterface で確認）
