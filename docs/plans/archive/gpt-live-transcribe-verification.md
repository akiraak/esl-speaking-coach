# GPT-Live-Transcribe の検証

2026-07-31 作成・同日完了。TODO の「GTP-Live-Transcrive の検証」（= OpenAI `gpt-live-transcribe`）に対応する。

## 検証結果（2026-07-31）: 今は見送り

**`gpt-live-transcribe` はサーバ VAD（turn_detection）非対応**で、発話終端・barge-in をサーバ VAD に頼る現行のターン制パイプラインにはそのまま組み込めない。採用するならクライアント側の発話終端検知（無音判定）+ 手動 `input_audio_buffer.commit` の実装が必要で、これは検証ではなく設計変更のタスクになるため見送る。

API を直叩きして実測した事実（スクリプト: セッション設定の総当たりと、`say` で生成した英語音声 4.2 秒のストリーミング）:

- `turn_detection: server_vad` / `semantic_vad` はどちらも **`invalid_value`（"Turn detection is not supported for this transcription model."）で拒否**される。受理されるのは明示 `null`（= 手動 commit）のみ。アプリ側から確認した際も同エラーで再接続ループ → 致命的エラー終了になった
- `turn_detection: null` なら **commit 前から delta が単語単位でストリームされる**（`delay: low` で音声より約 0.7 秒遅れ。ライブ字幕的な挙動）。ただし**末尾の数語は commit するまで保留**され、`completed`（確定テキスト）も commit への応答としてしか届かない。`speech_started` / `speech_stopped` に相当するイベントは無い
- 認識精度は簡易確認では良好（"Hello, I would like to talk about ramen today. I love miso ramen." を完全一致で認識）
- usage は **duration 型**（`{"type": "duration", "seconds": 5}`。4.19 秒の音声で 5 秒 = 秒単位切り上げ）。既存の `STTSegmentUsage.parse` の duration 分岐でそのまま拾える
- `languages`（配列）+ `delay` + `prompt` の組み合わせは受理される。`language`（単数）との併送は不可

### 実装に反映したもの（既定動作は不変）

切替の土台は残した。`-stt-model gpt-live-transcribe` で起動すると接続・live 字幕（partial 表示）までは動くが、**音声ターンは確定しない**（commit を送らないため）。テキスト入力は通常どおり動く。

- `OpenAITranscriptionConfiguration`: `delay` 追加、live 系判定、`sessionUpdate` の分岐（live は `languages` + `delay` + `turn_detection: null`、現行系は従来どおり）
- `DebugLaunchArguments`: `-stt-model` / `-stt-delay`（DEBUG のみ、`ChatRoomStore` で適用）
- `AIPricing`: live 系は `audioSeconds × $0.017 / 60` の分数課金
- テスト: `sessionUpdate` の live 分岐（`languages` / `language` なし / `delay` / `turn_detection` null）、料金計算

### 将来採用する場合のタスク（起こすなら別プラン）

1. クライアント側の発話終端検知: 既存の `SpeechLevelGate` / マイクレベル計測を土台に無音タイマーで `input_audio_buffer.commit` を送る
2. barge-in のクライアント判定（現在は STT の `speech_started` 起点）
3. 課金範囲の実測（usage の duration が commit した音声だけか、append した全音声かは未確認。常時ストリームする本アプリでは差が大きい）

## 目的・背景

- 2026-07-28 に OpenAI が新しい STT モデル 2 つを発表した
  - **`gpt-live-transcribe`**: 低レイテンシのライブ文字起こし用（本アプリの用途）
  - `gpt-transcribe`: 完成した音声ファイルの非同期文字起こし用（本アプリでは使わない）
- 公称では、アクセント・短い発話・数字・専門用語・騒音下の認識が `gpt-4o-transcribe` 系より改善している。本アプリの STT には**短い発話の言語誤判定**（"Hello" が他言語判定）、**prompt エコー幻覚**（`stt-prompt-echo-hallucination.md`）、**雑音の誤認識**（`noise-input-rejection.md`）という既知問題があり、モデル側の改善で軽くなる可能性がある
- 現行と同じ Realtime API の transcription セッション（`wss://api.openai.com/v1/realtime?intent=transcription`）でモデル名の差し替えだけで試せるため、切替可能にして実機で比較する

## API 差分（公式ドキュメント 2026-07-31 時点）

| 項目 | `gpt-4o-transcribe`（現行） | `gpt-live-transcribe` |
| --- | --- | --- |
| 言語ヒント | `language: "en"`（単数） | `languages: ["en"]`（配列）。**単数の `language` と併送してはいけない** |
| 認識バイアス | `prompt` | `prompt`（継続サポート）+ `keywords`（配列。`<>`・改行は不可） |
| レイテンシ調整 | なし | `delay`: `minimal` / `low` / `medium` / `high` / `xhigh`（低いほど partial が早く、高いほど WER 改善） |
| 課金 | トークン型（音声入力 $6/M ほか）≈ $0.006/分 | **セッション音声 $0.017/分**の分数課金 |

- サーバ VAD（`turn_detection: server_vad`）の設定体系は transcription セッション共通で、モデルには依存しない想定（疎通確認で `session.updated` が返ることを確認する）
- word-level timestamps / diarization / SRT 出力は非対応だが、本アプリでは未使用のため影響なし

### コスト上の要検証ポイント

`gpt-4o-transcribe` は「VAD が切り出した発話セグメントのみ」課金（`ai-cost-map.md` #1）だが、`gpt-live-transcribe` の「セッション音声 $0.017/分」が**送信した全音声（無音・AI 発話中含む）に効くのか、発話セグメント分だけなのか**は公式ドキュメントに明記がない。本アプリはバージイン検知のためセッション中ずっとマイク音声を流し続けるので、前者なら 30 分セッションで約 $0.51 と大きな差になる。実機検証時に OpenAI ダッシュボードの請求実績と突き合わせて確認する。

## 対応方針

デフォルトは `gpt-4o-transcribe` のまま変えず、DEBUG 起動引数で切り替えて比較できるようにする（TTS の `-tts-provider` と同型）。採用判断は実機比較後に別途行う。

### Phase 1: 切替の実装

- `OpenAITranscriptionConfiguration` に `delay`（Optional。未指定ならサーバ既定）と live 系判定を追加
- `sessionUpdate` の transcription 部をモデルで分岐: live 系は `languages` 配列 + `delay`、現行系は従来どおり `language` 単数。`prompt` と VAD 設定は共通
- `DebugLaunchArguments` に `-stt-model` / `-stt-delay` を追加し、`ChatRoomStore.launchSession` の DEBUG ブロックで適用
- `AIPricing`: モデル名が `gpt-live-transcribe` 系なら `audioSeconds × $0.017 / 60` で概算（usage は duration 型で届く想定。tokens 型しか来ない場合は生 usage から後で再計算する）
- `docs/specs/ai-cost-map.md` の単価表に検証中モデルとして追記
- テスト: `sessionUpdate` の JSON 形（`languages` 配列 / `language` キーなし / `delay` の有無）、`AIPricing` の分数課金

### Phase 2: シミュレータ疎通確認

- ユニットテスト + `xcodebuild` でビルド確認
- `-stt-model gpt-live-transcribe -stt-delay low -start-conversation` で起動し、session.update が受理されて ready に到達すること（STT API エラーが出ないこと）を診断ログで確認する
- シミュレータはマイク無効のため、精度・レイテンシの検証はできない（疎通のみ）

### Phase 3: 実機検証（ユーザー）

`./run-install-iphone.sh -stt-model gpt-live-transcribe -stt-delay low` で通常どおり会話し、現行と比較する。

- 認識精度: 短い発話（"Hello" 等）の言語誤判定、雑音セグメントの誤認識、prompt エコー幻覚の再現有無
- レイテンシ: 発話終端 → 確定テキストまでの体感（`delay` の値も `low` / `medium` で振ってみる）
- 料金: 管理画面の料金タブの記録と OpenAI ダッシュボードの請求実績を突き合わせ、「セッション音声」の課金範囲を確認する（上記の要検証ポイント）
- 採用判断: 精度・レイテンシの改善がコスト増（最大 ~3 倍、課金範囲次第でそれ以上）に見合うか。採用する場合のデフォルト切替・`keywords` 活用は別タスクに切り出す

## 影響範囲

- 既定動作は変えない（DEBUG 起動引数を付けたときだけモデルが変わる）
- 変更ファイル: `OpenAITranscriptionProtocol.swift` / `DebugLaunchArguments.swift` / `ChatRoomStore.swift` / `AIPricing.swift` / `docs/specs/ai-cost-map.md` / `CloudPipelineProtocolTests.swift` / `AIPricingTests.swift`

## テスト方針

- ユニットテスト: `sessionUpdate` の live 分岐の JSON 形、料金計算
- シミュレータ: 疎通（session.updated 受理 → ready 到達）
- 実機: 精度・レイテンシ・課金範囲の比較（ユーザーが実施）
