# 音声入力が周囲の雑音・他人の声を拾ってしまうのの改善

## 目的・背景

音声モードで会話していると、学習者本人が話していないのに入力が確定してしまうことがある。

- 家族・テレビ・店内 BGM などの**他人の声**がユーザー発話として書き起こされ、Claude がそれに応答する
- 咳・物音・エアコンなどの**非発話ノイズ**でサーバ VAD が発火し、AI の読み上げが barge-in で切られる
- 上記の結果、会話が中断したり、脈絡のない発話が履歴に混ざって以降のターンの文脈まで汚れる

特に厄介なのは、拾った雑音が `bye` / `thank you` 系に化けたときで、Claude が別れの台本 + 制御行 `[end]` を
出してセッションが勝手に終了する（[conversation-design.md](../specs/conversation-design.md) のセッション終了仕様）。

関連する既存対策として、非発話セグメントで STT が認識バイアス用 prompt をそのまま書き起こす幻覚
（prompt leakage）は `STTHallucinationFilter` で対処済み（`docs/plans/archive/stt-prompt-echo-hallucination.md`）。
本タスクはその調査で「スコープ外」「実機で併用検討」として残した部分（VAD 閾値・誤 barge-in・
一般的なノイズ由来の書き起こし）を引き取る。

## 現状の実装

| 層 | 現状 | ファイル |
| --- | --- | --- |
| オーディオセッション | `.playAndRecord` / mode `.voiceChat` / `.defaultToSpeaker` | `TurnBasedVoiceSession.start()` |
| エコーキャンセル | Voice Processing I/O 有効（バッファが 2 秒届かなければ無効化して再起動する watchdog あり） | `MicrophoneCapture.start(voiceProcessing:)` / `startMicWatchdog()` |
| マイク送出 | セッション中は**常時** PCM16 24kHz を STT へ流す（読み上げ中も止めない = barge-in 用） | `startMicrophoneStreaming()` |
| 発話終端 | サーバ VAD。`silence_duration_ms: 800` のみ指定、**`threshold` は未指定（既定 0.5）** | `OpenAITranscriptionClientEvent.sessionUpdate` |
| ノイズ低減 | `noise_reduction: near_field` | 同上 |
| barge-in | `speech_started` を受けた**瞬間**に Claude キャンセル + TTS 停止 | `handleSpeechStarted()` |
| transcript の採否 | trim して空でなければ採用（+ prompt エコーのみ破棄） | `handleSTT` の `.finalTranscript` |
| RMS レベル | 波形表示用に `micLevel` として UI へ流すだけ。**採否判定には一切使っていない** | `startLevelMonitor()` |

つまり「本人の声かどうか」を判定する仕組みは**どこにも無く**、サーバ VAD が発話と判定して
gpt-4o-transcribe が空でない文字列を返せば、そのまま会話に入る。

## 原因の切り分け

1. **VAD が敏感すぎる**: `threshold` 未指定（既定 0.5）+ `near_field` のため、小さな物音・遠くの声でも
   セグメントが切り出される。切り出された以上、STT は「何か」を書き起こそうとする
2. **距離・音量による選別をしていない**: 本人の声（口元 20〜40cm）と部屋の向こうのテレビでは
   入力レベルが大きく違うのに、クライアント側でその差を使っていない
3. **transcript の内容フィルタが prompt エコー限定**: Whisper 系に特有の定型幻覚
   （"Thank you for watching." / "Bye." / "you" / "。" 等）や、雑音由来の 1〜2 語の断片が素通りする
4. **barge-in が即断**: `speech_started` 単独で応答を止めるため、実際には発話ではなかった場合でも
   読み上げが切られる。しかも切られた assistant ターンは読み上げ済みぶんまでで履歴確定されるので、
   AI の発言が途中で切れた状態が会話に残る
5. **読み上げ中もマイクを送り続ける**: AEC が効いていれば自分の TTS は消えるが、watchdog が VP を
   無効化した端末（コメントに明記あり）ではスピーカー出力が回り込む

## 調査: gpt-4o-transcribe / Realtime transcription で使えるテクニック（2026-07-27）

公式ドキュメント・コミュニティを調べ、この構成（Realtime API の transcription セッション +
`gpt-4o-transcribe`）で**実際に使える**ものを整理した。出典は末尾。

| # | テクニック | 使えるか | 効果 / 注意 |
| --- | --- | --- | --- |
| 1 | `turn_detection.threshold`（0.0〜1.0・**既定 0.5**） | ✅ 未使用 | 公式が「高くすると騒がしい環境で有利」と明記。最も素直な第一手 |
| 2 | `turn_detection.prefix_padding_ms`（**既定 300**） / `silence_duration_ms`（transcription セッションの**既定は 500**） | ✅ silence のみ指定済（800） | prefix は既定のまま明示指定して固定するのが安全。なお実装コメントの「既定 200ms」は現行ドキュメントと食い違うので、実測で確認する |
| 3 | `noise_reduction: near_field / far_field` | ✅ near_field 指定済 | **VAD とモデルに渡る前段でフィルタされる**ため、書き起こし精度だけでなく VAD の誤発火も減る。本人が端末に近い前提なので near_field のまま。ただし transcription や semantic_vad と併用したときにセッション 5 分あたりから極端なレイテンシ悪化が出るという未解決の報告（2025-05）があるので、Phase 0 の計測で監視する |
| 4 | `include: ["item.input_audio_transcription.logprobs"]` | ✅ 未使用・**有力** | セグメントごとの logprobs が完了イベントに載る。平均 logprob を信頼度スコアにして低信頼セグメントを破棄できる。ただし Whisper 系の研究では**幻覚は高信頼で出ることがある**ため、単独では不十分（レベルゲートとの併用前提） |
| 5 | `turn_detection: null` + 自前 VAD + `input_audio_buffer.commit` | ✅ 未使用・**最強手** | サーバ VAD を切り、クライアントが「これは本人の発話」と判断した区間だけを commit する。雑音は**そもそも書き起こされない**ので STT 料金も減る。実装コストと、無音待ちを自前で持つことによる終端判定の作り込みが必要 |
| 6 | `transcription.delay`（`minimal` 〜 `xhigh`） | ⚠️ 要確認 | GA のリファレンスにある精度 / レイテンシのトレードオフ設定。会話のレイテンシに直結するため上げるとしても `low` まで。効果は実測しないと不明 |
| 7 | `prompt`（自由文・**224 トークン上限**） | ✅ 使用中 | 認識バイアス用。ただし本件の prompt エコー幻覚の原因でもある（対策済み）。「英語以外・非発話は書き起こさない」系の指示を足せるかは実測次第で、prompt を伸ばすほどエコー時の被害も増える点に注意 |
| 8 | `semantic_vad`（意味で終端判定する VAD） | ❌ 使えない | transcription セッションの `turn_detection.type` は **`server_vad` のみ**サポート（speech-to-speech 用の機能）。この線は追わない |
| 9 | `gpt-4o-transcribe-diarize` + `known_speaker_names[]` / `known_speaker_references[]`（参照音声 4 件まで） | ❌ 現時点では使えない | 話者分離 + **声の登録による本人判定**という本件にドンピシャの機能だが、`/v1/audio/transcriptions`（ファイル API）向けで、Realtime transcription セッションでの利用は「アクセス権が無い」エラーの報告のみで公式回答なし。将来 Realtime で開放されたら本命候補として再検討する |
| 10 | モデル差し替え（`gpt-4o-mini-transcribe` / `gpt-realtime-whisper`） | 参考 | whisper-1 の "Thank you for watching" 系幻覚は gpt-4o-transcribe でほぼ解消したという報告がある。つまり Phase 3 の定型幻覚リストは**優先度が低い**（保険として薄く入れる程度でよい） |

**調査から得た方針の修正:**

- #1・#4 は API を数行変えるだけで効くので、自前のレベルゲート（Phase 2）より**先に**試す
- #5 は本件に対する最も確実な解だが手術が大きい。#1 + #4 + レベルゲートで足りなければ移行する、という順序にする
- #9 が使えないため「声で本人を識別する」路線は当面あきらめ、**音量（＝距離）と信頼度**で近似する方針を維持する

## 対応方針

「サーバ VAD の手前で減らす」→「クライアントのレベルで落とす」→「transcript の内容で落とす」の
多段フィルタにする。単一の対策で消し切ろうとすると、本人の小声の話し始めを取りこぼす方向へ倒れるため、
**各段は控えめな閾値**にして重ねる。

### Phase 0: 実測できるようにする（前提）

現状は「何が捨てられ / 拾われたか」が実機で追えないため、まず観測を入れる。判断材料なしに閾値だけ動かさない。

- セグメント単位の診断ログを管理画面の会話ログ（`ChatSessionLogRecord` の `kind = metrics`）へ残す:
  `speech_started` からの継続時間、その間の RMS の平均 / 最大、確定 transcript、採用 / 破棄の別と破棄理由
- トーク画面には出さない（`docs/plans/archive/hide-debug-notices-in-chat.md` の方針どおり）
- これを持って実機でノイズ環境（テレビ / 家族の会話 / カフェ）を再現し、Phase 1〜3 の閾値を決める

### Phase 1: サーバ VAD を鈍くする（採用・即効）

`turn_detection` に明示指定を追加する（調査 #1・#2）。

- `threshold` を明示（既定 0.5 → **0.6 を初期値**に、実機で 0.55〜0.7 を調整）
- `prefix_padding_ms` を既定値 300 で明示指定して固定する（短くすると語頭が欠けるため下げない）
- `noise_reduction` は `near_field` のまま（本人が端末に近い前提。`far_field` は遠くの声を持ち上げるので逆効果）
- 読み上げ中（`state == .speaking`）だけ `session.update` で `threshold` を一段上げる案も検討する。
  誤 barge-in を減らせるが、本人の割り込みも入りにくくなるためトレードオフ。Phase 4 の実測後に判断する

### Phase 2: logprobs による信頼度ゲート（採用・API 側で完結）

調査 #4。セッションに `include: ["item.input_audio_transcription.logprobs"]` を足すと、
確定イベントにトークンごとの logprobs が載る。

- `STTSegmentUsage` と同様に純関数でパースし、平均 logprob（と最小値）を信頼度スコアにする
- スコアが閾値を下回るセグメントは破棄する。閾値は Phase 0 の実測（本人の正常発話の分布 vs 雑音セグメント）から決める
- **単独では信用しない**: 幻覚が高信頼で出るケースが報告されているため、Phase 3 のレベルゲートと
  OR ではなく「どちらかが強く否定したら破棄」程度の重ね方にし、初期閾値は保守的に置く
- スコアは Phase 0 の診断ログにも出し、閾値を後から見直せるようにする

### Phase 3: クライアント側のレベルゲート（採用）

セグメントの音量が「部屋の暗騒音」と大差ないなら、書き起こしの内容に関わらず捨てる。

- `AudioTapRouter` / `MicrophoneCapture` にセグメント区間の RMS 統計（平均・最大）を取れる API を足す
  （`TurnBasedVoiceSession` が `speechStarted` 〜 `speechStopped` の区間で集計する形でも可）
- 暗騒音のフロアは固定値ではなく**追従**させる: 発話していない区間の RMS の移動中央値をノイズフロアとし、
  セグメント最大 RMS がフロアに対して一定比（SNR 相当。初期値は Phase 0 の実測から決める）に届かなければ破棄
- 破棄したセグメントは空セグメントと同じ扱い（`commitPendingTurnIfReady` で listening へ戻す）
- 純関数（ノイズフロア推定 + 採否判定）に切り出してユニットテストする

### Phase 4: transcript の内容フィルタ（採用・ただし薄く）

`STTHallucinationFilter` を prompt エコー専用から「ノイズ由来 transcript の判定」へ広げる。
調査 #10 のとおり whisper-1 由来の定型幻覚は gpt-4o-transcribe ではほぼ出ないという報告があるため、
**保険として薄く入れる**位置づけにし、ここで頑張りすぎない。

- Whisper 系の定型幻覚リスト（"thank you for watching" / "thanks for watching" / "you" / "bye" 単独 /
  "." "。" のみ 等）に**完全一致**したセグメントは、Phase 2 のレベル判定が弱かった場合に限り破棄する
  - 単語単独の "Bye." は本人の正当な発話でもあり得るため、**内容だけでは切らない**。
    「短い（1〜2 語）」かつ「レベルが低い」の AND 条件にする
- 記号・空白のみ、非 ASCII のみ（英語セッションなので日本語だけの transcript は誤認識の可能性が高い）も破棄候補
- 破棄理由を Phase 0 のログに残す

### Phase 5: barge-in を「確からしい発話」に限定（採用）

`speech_started` の即断をやめる。

- `speech_started` を受けても即座には Claude / TTS を止めず、**短い猶予**（150〜250ms 目安）のうちに
  partial transcript が届く、またはレベルがゲートを超えた場合にのみ割り込み確定とする
- 猶予中に `speech_stopped` が来て空セグメントに終わったら、割り込みは無かったものとして
  読み上げ・生成をそのまま継続する（現状は打ち切られてしまう）
- 実装は状態機械の変更になるため、既存の barge-in テスト（あれば）と合わせて回帰を確認する

### エスカレーション先（Phase 1〜5 で足りなかった場合）

- **サーバ VAD を切って自前 VAD + 手動 commit（調査 #5）**: `turn_detection: null` にし、
  クライアントが本人の発話と判断した区間だけ `input_audio_buffer.commit` で確定する。
  雑音がそもそも書き起こされないので確実性が最も高く、STT 料金も下がる。ただし発話終端判定
  （現在サーバ VAD が担っている 800ms の無音待ち）を自前で作り込む必要があり、
  Phase 3 のレベルゲートをそのまま流用できる形にしておく
- **プッシュトゥトーク（押している間だけ聞く）モード**: 雑音環境では確実だが、ハンズフリー連続という
  音声モードの設計（[screen-layout.md](../specs/screen-layout.md)）を変えることになるため最終手段

### 見送り（今回はやらない）

- **話者識別 / 声紋による本人判定**: 調査 #9 のとおり `gpt-4o-transcribe-diarize` の
  `known_speaker_references[]`（参照音声の登録）が機能としては存在するが、ファイル API 向けで
  Realtime transcription セッションでは利用できない。Realtime で開放されたら本命候補として再検討する。
  当面は Phase 2（信頼度）+ Phase 3（音量 ≒ 距離）で近似する
- **`semantic_vad`**: 調査 #8。transcription セッションでは `server_vad` のみサポートで使えない
- **`transcription.delay` の引き上げ（調査 #6）**: 精度は上がりうるが会話レイテンシに直結する。
  Phase 0 の実測で「認識自体の精度」が問題だと分かった場合にのみ検討する
- **認識バイアス用 prompt の削除**: 短い発話の言語誤判定対策として維持する（前回調査と同じ）

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Voice/CloudPipeline/OpenAITranscriptionProtocol.swift` | `OpenAITranscriptionConfiguration` に `threshold` / `prefix_padding_ms` 追加、`sessionUpdate` の `turn_detection` へ反映。session に `include: ["item.input_audio_transcription.logprobs"]` を追加し、完了イベントから logprobs をパースして信頼度スコアにする純関数を追加。`STTHallucinationFilter` をノイズ判定へ拡張 |
| `Voice/CloudPipeline/OpenAITranscriptionStream.swift` | logprobs を載せた確定イベントを `STTStreamEvent` へ流す（`.finalTranscript` に信頼度を添える or 別イベント） |
| `Voice/MicrophoneCapture.swift` | セグメント区間の RMS 統計を取れるようにする |
| `Voice/TurnBasedVoiceSession.swift` | レベルゲートの適用（`.finalTranscript`）、barge-in の猶予判定（`handleSpeechStarted`）、診断ログの発行 |
| `Voice/`（新規） | ノイズフロア推定 + 採否判定の純関数（テスト対象） |
| `Conversation/ChatRoomStore.swift` | 診断ログを `ChatHistoryStore.appendLog` へ流す（既存経路に乗る想定。要確認） |
| `docs/specs/conversation-design.md` | 発話検出・採否の仕様として決定値（閾値）を追記 |

会話履歴・永続化スキーマの変更は無い見込み（診断ログは既存の `ChatSessionLogRecord` を使う）。

## テスト方針

- **ユニットテスト**: ノイズフロア推定と採否判定（無音続き / 本人発話 / 遠い声を模した系列）、
  logprobs のパースと信頼度スコア算出（欠落時に破棄側へ倒れないこと）、
  拡張後の `STTHallucinationFilter`（定型幻覚は短く弱いときのみ破棄 / 正当な "Bye." は通す /
  既存の prompt エコー判定が壊れていない）、`sessionUpdate` の JSON に `threshold` /
  `prefix_padding_ms` / `include` が載ること
- **ビルド**: `xcodebuild`（シミュレータ）でビルドと全テストを通す
- **実機**（本タスクの本丸。シミュレータではマイクを使えない）:
  1. 静かな環境で通常どおり会話でき、話し始めの語頭が欠けないこと（後退が無いこと）
  2. テレビ / 家族の会話を鳴らしながら黙っていて、発話が commit されないこと
  3. 読み上げ中に咳・物音を立てても読み上げが切れず、本人が話し始めたときは従来どおり割り込めること
  4. 管理画面の会話ログに、破棄されたセグメントと理由が残っていること

## Phase 構成

1. **Phase 0**: セグメント診断ログ（管理画面のみ）→ 実機でノイズ環境を実測し閾値の初期値を決める
2. **Phase 1**: サーバ VAD の `threshold` / `prefix_padding_ms` を明示指定
3. **Phase 2**: logprobs 信頼度ゲート（`include` 追加 + スコア算出 + 破棄判定）
4. **Phase 3**: クライアント側レベルゲート（ノイズフロア追従 + SNR 判定）
5. **Phase 4**: transcript 内容フィルタの拡張（薄く）
6. **Phase 5**: barge-in の猶予判定
7. **Phase 6**: 実機で総合確認 → 決定した閾値を `conversation-design.md` へ反映、プランを archive へ

Phase 1・2 は API 側の設定変更だけで効くので先に入れ、そこで一度実機確認する。十分に改善していれば
Phase 3 以降は実測に応じて縮小してよい（過剰にフィルタを重ねて本人の発話を取りこぼす方が
体験上の害が大きい）。逆に Phase 5 まで入れても他人の声を拾うなら、エスカレーション先の
「サーバ VAD を切って自前 VAD + 手動 commit」へ進む。

## Phase の取捨選択（2026-07-27 決定）

上記 Phase を効果・コストで分類し、**Phase 1 → 実機確認 → Phase 3** の最短経路だけを実施する方針に絞った。

| Phase | 判断 | 理由 |
| --- | --- | --- |
| 1（VAD threshold / prefix_padding） | **実施**（完了） | 公式が騒音環境での対処として明記している正攻法で、変更は数行。最優先 |
| 3（レベルゲート） | **実施**（Phase 1 の実機確認後） | テレビ・家族の声は内容では区別できず、音量（＝距離）でしか切れない。本タスクの本質的な対策 |
| 6（実機総合確認 + 仕様反映） | **実施** | 決定した閾値を仕様へ残す |
| 0（診断ログ） | **見送り** | Phase 1・3 の 2 段だけなら実機での体感評価で判断できる。閾値の追い込みで数値が要るとなった時点で足す |
| 2（logprobs 信頼度ゲート） | **見送り** | 幻覚が高信頼で出る報告（調査 #4）があり破棄判定の根拠として弱い。Phase 3 で音量が使える以上、優先度が低い |
| 4（transcript 内容フィルタ） | **見送り** | gpt-4o-transcribe では定型幻覚がほぼ出ない（調査 #10）。「短い AND レベルが低い」は Phase 3 の部分集合でしかなく、正当な "Bye." を落とすリスクだけが残る |
| 5（barge-in 猶予） | **保留** | 雑音混入とは別問題（読み上げが物音で切れる）。Phase 1 の threshold 引き上げで誤発火自体が減るため、実機で再現し続けたら別タスクとして起票する |

### Phase 1 の実装結果（2026-07-27）

`OpenAITranscriptionConfiguration` に `vadThreshold = 0.6` / `prefixPaddingMs = 300` を追加し、
`sessionUpdate` の `turn_detection` へ反映した。あわせて `silenceDurationMs` のコメントにあった
「既定 200ms」を現行ドキュメントの 500ms に訂正した（調査 #2）。ユニットテストは既存の
`testTranscriptionSessionUpdateFollowsGAShape` を拡張して 3 値すべてを固定。

実機の初回起動で `Invalid 'session.audio.input.turn_detection.threshold': max decimal places
exceeded`（上限 16 桁）になった。`JSONSerialization` が `Double` の 0.6 を
`0.59999999999999998` と 17 桁で書き出すため。小数 2 桁へ丸めた `NSDecimalNumber` に変換して
送るようにし（`OpenAITranscriptionClientEvent.jsonNumber`）、**JSON の文字列**を検査する
回帰テストを追加した（パース後の `Double` を見ても検出できない）。リクエスト JSON に載る
小数は他に無いことを確認済み。全 129 件パス。**閾値の効果自体は実機確認待ち**。

### Phase 3 の実装結果（2026-07-27）

`Voice/SpeechLevelGate.swift`（新規）に純粋な値型として実装した。

- `SegmentLevelMeter`: タップバッファごとの RMS を受け取り、**非発話区間の移動中央値**を暗騒音、
  `speech_started` 〜 `speech_stopped` の区間を 1 セグメントとして peak / mean を集計する。
  集計は `AudioTapRouter.process`（オーディオスレッド・ロック下）で行う。
  UI 用の `levels` ストリームは `.bufferingNewest(1)` で取りこぼすため判定には使えない
- **遡り（lookback 約 0.5 秒）**: `speech_started` はサーバ VAD の判定 + ネットワーク往復のぶん
  遅れて届くので、直近サンプルまで遡ってピークに含める。語頭が窓の外に落ちるのを防ぐ
- **読み上げ中は暗騒音の更新を止める**（`state == .speaking` で suppress）。VP を無効化した端末で
  スピーカー出力が回り込み、フロアが持ち上がって直後の本人発話を弾くのを防ぐ
- `SpeechLevelGate.verdict(for:)` の初期閾値: `snrRatio 3.0` / `minimumPeak 0.01` /
  `unconditionalPeak 0.05`（この値以上なら無条件採用）/ `minimumSampleCount 3`。
  **計測できない・フロア不明・サンプル不足はすべて採用側へ倒す**（取りこぼしの害の方が大きいため）
- 判定は `.finalTranscript` で適用し、破棄は空セグメントと同じ扱い（`commitPendingTurnIfReady`）。
  セグメントと統計の対応は `pendingSegmentLevels` のキューで取り、再接続時はクリアして採用側へ倒す
- 閾値を実機で追い込めるよう、**採否と実測値（peak / mean / floor / 比）を毎セグメント会話ログへ**
  出す（`.info` → 管理画面のみ。トーク画面には出さない）。Phase 0 の代替として最小限のもの

テレビが鳴りっぱなしの部屋では暗騒音の推定自体が持ち上がるため、「それより明確に大きい音」＝
本人の声だけが通る、というのがこのゲートの効きどころ。ユニットテスト 17 件追加・全 146 件パス。
**実機未確認**（シミュレータではマイクを使えないため、閾値の妥当性は実機での確認待ち）。

## 出典（2026-07-27 時点）

- [Voice activity detection (VAD) | OpenAI API](https://developers.openai.com/api/docs/guides/realtime-vad) — `threshold` / `prefix_padding_ms` / `silence_duration_ms`、騒音環境では threshold を上げる指針、`semantic_vad` の `eagerness`
- [Create transcription session | OpenAI API Reference](https://developers.openai.com/api/reference/resources/realtime/subresources/transcription_sessions/methods/create) — transcription セッションの schema（`turn_detection.type` は server_vad のみ、既定値、`include: item.input_audio_transcription.logprobs`、`delay`）
- [Realtime transcription | OpenAI API](https://developers.openai.com/api/docs/guides/realtime-transcription) — GA の `session.update` 形式、noise_reduction が VAD の前段で効くこと
- [Speech to text | OpenAI API](https://developers.openai.com/api/docs/guides/speech-to-text) — `prompt`（224 トークン上限・gpt-4o 系は自由文）、logprobs による信頼度
- [GPT-4o Transcribe Diarize Model | OpenAI API](https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize) / [How to enable gpt-4o-transcribe-diarize for realtime transcription?](https://community.openai.com/t/how-to-enable-gpt-4o-transcribe-diarize-for-realtime-transcription/1373561) — `known_speaker_names[]` / `known_speaker_references[]` と、Realtime では使えない旨の報告
- [Realtime API with noise_reduction has sudden increase of latency](https://community.openai.com/t/realtime-api-with-noise-reduction-has-sudden-increase-of-latency/1256390) — noise_reduction × transcription のレイテンシ悪化報告（未解決）
- [How I Completely Eliminated Whisper-1 Hallucinations by Switching to gpt-4o-transcribe](https://zenn.dev/daishiro/articles/whisper-hallucination-gpt4o-transcribe) — whisper-1 の定型幻覚が gpt-4o-transcribe でほぼ解消したという報告
- [Whisper Hallucination Detection and Mitigation via Hidden Representation Steering and Sparse AutoEncoders](https://arxiv.org/pdf/2606.07473) — 幻覚が高い avg_logprob で出ることがある（信頼度フィルタ単独では不十分）
