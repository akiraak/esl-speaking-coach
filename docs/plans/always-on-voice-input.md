# いつでも話せる音声入力（話しかけの窓 + ターンの締め方）

2026-08-04 作成 / 同日改訂。調査 + 実装プラン。

改訂で扱う範囲を 2 つに広げた。元は「AI ターン中に話せるか（ターンの**外**）」だけだったが、
実際に会話していて頻度が高い不満は「自分のターンをいつ締めるか（ターンの**中**）」の方だった。
どちらも `TurnBasedVoiceSession` の同じ導線を触るので 1 本のプランにまとめる。

## 目的・背景

### A. AI のターン中に話しかけられない

- 現状、live 経路の音声入力は**自分が話すターン（listening）のときだけ**開いている
  （`docs/plans/archive/turn-gated-voice-input.md`）。AI の thinking / speaking 中は入力ごと止まるため
  **音声での barge-in が無い**
- これでノイズ由来の誤爆は減ったが、**会話としては話しづらい**。相手が話している途中で
  「Ah, I see」「Wait—」と被せられないのは、発話量を稼ぐという目的（CLAUDE.md）にも逆行する
- 一方、ターン制にする前（4o + サーバ VAD の常時入力 + 即時 barge-in）は、**物音・テレビ・
  家族の声で読み上げが切れる / 変なテキストがターンとして送られる**という問題があった
  （`docs/plans/archive/noise-input-rejection.md`）

### B. 言い淀むとターンが途中で締まる / 言い直せない

実会話でより頻度が高いのはこちら。

- **言葉に詰まると、続きを言う前にターンが送られてしまう。** 無音 0.8 秒
  （`silenceDuration`）で終端し、`commitPendingTurnIfReady()` が**即座に** Claude へ投げるため、
  `"I went to the... "` のような中途半端なテキストがそのまま会話ターンになる
- **言い終わってから「違った」と思っても言い直せない。** 送信を取り消す導線が無い

**操作は声だけで完結させる**（作者判断 2026-08-04）。ボタン・スワイプでの取り消しは作らない。
「追加で話すこと」がそのまま言い足し・言い直しになる形にする。

**ゴール**: ①言い淀んでもターンが途中で締まらない ②言い終わった直後なら声だけで言い直せる
③AI のターン中でも話しかけられる。そのうえで ④ノイズで読み上げが切れない
⑤ノイズが会話ターンとして送られない ⑥自分の読み上げ音声（エコー）で自滅しない。

## 現状の整理（どこで何が決まっているか）

| 役割 | 場所 | 現状 |
| --- | --- | --- |
| 入力の窓（送信ゲート） | `AudioTapRouter.setSpeechGateOpen(_:)` / `TurnBasedVoiceSession.syncVoiceInputGate()` | `state == .listening && 音声入力有効` のときだけ開く。閉時は VAD 判定・遡り蓄積・append を丸ごとスキップ |
| 発話開始 / 終端の検知 | `ClientSpeechEndpointer` | エネルギー VAD。閾値は管理画面「音声入力」で調整可（`VoiceInputSettingsStore`） |
| 認識後の採否 | `SpeechLevelGate.verdict(for:)` | セグメントの peak / 暗騒音比で棄却。棄却は空セグメント扱い |
| 幻覚よけ | `STTHallucinationFilter.isPromptEcho` | STT が認識バイアス prompt をそのまま返した場合に破棄 |
| **ターンの締め** | `commitPendingTurnIfReady()` | 確定テキストが揃った**瞬間に** `commitText()` → `startClaudeTurn()`。猶予ゼロ |
| **複数セグメントの連結** | `pendingTurnText`（`TurnBasedVoiceSession.swift:561`） | 同一ターン内の複数セグメントを空白で連結する仕組みが**すでにある** |
| **user ターンの結合** | `appendUserMessage(_:)`（同 664 行） | `history.last` が user なら**追記する**。barge-in で assistant 応答が空だった場合の受け皿として既存 |
| assistant ターンの確定 | `commitAssistantTurn(onlyBegun:)` | barge-in では**読み上げ開始済みの発話だけ**履歴に残し、未読み上げは破棄 |
| 割り込み | `handleSpeechStarted()` | `.speechStarted` を受けた瞬間に `interruptAssistantTurn()`。**live ではゲートが閉じているので発火しない**（4o 経路のみ生きている） |

ノイズ対策の層（暗騒音追従・SNR・最小継続・レベルゲート・空セグメント無音化）は既にあり、
**ターン制ゲートはその上に重ねた最後の 1 枚**。この 1 枚だけを外すと 4o 時代の誤爆に戻る。

一方で B に効く部品（`pendingTurnText` の連結、`appendUserMessage` の結合、
`commitAssistantTurn(onlyBegun:)` の選択的破棄）は**すでに揃っている**。足りないのは
「締めるまでの時間」だけ。

## 中心となる考え方: 回収ウィンドウ

`commitPendingTurnIfReady()` が即断しているのを、**「まだ自分のターンが続いている時間」**に置き換える。
この窓の中で検知された発話は、新しいターンにせず**直前の自分の発言へ合流させる**。

| 段階 | 状態 | 追加発話が来たら | 捨てるもの |
| --- | --- | --- | --- |
| ① 猶予 | 終端後・送信前 | `pendingTurnText` へ継ぎ足すだけ | なし |
| ② thinking | 送信済み・生成中 | Claude ターンを捨て、user メッセージへ継ぎ足して再送 | Claude の入力（キャッシュ読み）+ 出力の途中まで |
| ③ 読み上げ直後 | 再生開始から `redoWindow` 秒以内 | 読み上げを止め、**吹き出しごと破棄**して継ぎ足し再送 | ②に加えて TTS 1 秒ぶん |
| ④ それ以降 | 読み上げ中 | 通常の barge-in（**新しい**ターン。読み上げ済みは履歴に残す） | 未読み上げの発話 |

①②③はすべて「言い足し・言い直し」で、履歴上は 1 つの user メッセージに合流する
（`appendUserMessage` が自動でやる）。④だけが別ターン。

**`redoWindow`（1 秒目安）がかかるのは③だけで、①②には時間制限を設けない。**
②は Chobi がまだ音を出していない＝エコーが無く listening と同じしきい値で安全に聞けるうえ、
捨てるものも軽い（吹き出しは未表示、止めるべき再生も無い）ため、thinking の全区間を回収対象にする。
③にだけ制限を置くのは、鳴っている声がマイクへ漏れる誤爆の危険が時間とともに積み上がるから。

窓の実長は `① 猶予 + ② TurnMetrics の「発話終端 → 再生開始」 + ③ redoWindow`。
②が体感レイテンシそのものなので、**①②だけで数秒稼げる**。
③は取りこぼしを拾う最後のひと押しという位置づけで、Phase 2 の実測で partial が
1 秒以内に届かないと分かったら**③を落として②までで確定してよい**（Phase 4 の判断点）。

`"I went to the station... I mean, the airport"` のように**言い直しの言葉ごと** Claude に届くので、
前半を消す必要はない。Claude は自己訂正を自然に扱える。

### 体験としてどう見えるか

- ①: 何も変わらない（聞き取り中のまま。ジングルもまだ鳴らない）
- ②: 「考え中」表示が消えて聞き取りに戻る
- ③: 読み上げがフッと止まり、出かけていた吹き出しが**消え**、自分の吹き出しに文が足される

## 問題の分解（A 側）

今は 2 つの別々の決定が 1 つの `isSpeechGateOpen` に束ねられている。

1. **音声を STT へ送るか**（入力の窓）
2. **AI のターンを止めるか**（割り込み）

「前の挙動」は 1 も 2 も常時 ON かつ**即断**だった。今は 1 も 2 も OFF。
**1 は開けたまま、2 だけを「確からしい発話」に限定する**のが中庸。
なお 2 の遅延確定は `noise-input-rejection.md` の Phase 5 として起票され、当時は
「雑音混入とは別問題」として**保留**になっていたものと同じ考え方。

## 案の比較

### A 側（AI ターン中の入力）

| 案 | 内容 | 会話のしやすさ | ノイズ耐性 | 判断 |
| --- | --- | --- | --- | --- |
| A1 | 現状維持（ターン制ゲート） | × 被せられない | ◎ | 比較の基準 |
| A2 | 常時入力 + 即時 barge-in（旧 4o 挙動） | ◎ | × 物音で読み上げが切れる | 却下（戻すだけ） |
| A3 | **常時入力 + 割り込みは確認後に確定** | ○ 被せられる（停止まで数百 ms） | ○ 確認で弾く | **採用** |
| A4 | 常時入力 + 割り込みしない（読み上げ終了後に投入） | △ 話せるが相手は止まらない | ○ | A3 の劣化系として内包 |
| A5 | 押している間だけ聞く（PTT）/ 割り込みボタン | × ハンズフリーでなくなる | ◎ | 見送り（声だけで完結させる方針に反する） |

### B 側（ターンの締め方）

| 案 | 内容 | 詰まり | 言い直し | 判断 |
| --- | --- | --- | --- | --- |
| B1 | `silenceDuration` を 0.8 → 2.0 秒へ上げる | ○ | × | 却下。**全ターンが遅くなる**うえ、無音 2 秒ぶんがセグメントに入って STT 課金も伸びる |
| B2 | **終端後に送信を待つ（猶予）+ 追加発話は継ぎ足し** | ◎ | △ | **採用**（①） |
| B3 | 猶予中に取り消しボタン | – | ○ | 却下（声だけで完結させる方針） |
| B4 | **送信後・読み上げ直後も声で回収する** | – | ◎ | **採用**（②③） |

**B1 ではなく B2 を採る理由**が肝。B1 は無音 2 秒ぶんを丸ごとセグメントに含めてから STT へ送るので、
**認識の開始そのものが遅れる**。B2 は 0.8 秒でセグメントを切って認識を先に走らせ、**送信だけ**待つ。
猶予タイマーを `.speechStopped` の時点で開始すれば **STT の確定待ちと並行する**ので、
STT 確定に 400ms かかっているなら猶予 1.0 秒の実質上乗せは 0.6 秒で済む。

## 対応方針

### 1. 送信猶予（①）

- `commitPendingTurnIfReady()` から `commitText()` を直接呼ばず、`commitGrace` 秒の
  タイマーを挟む。タイマーは **`.speechStopped` の時点で開始**する（STT 確定待ちと並行させる）
- 猶予中に `.speechStarted` が来たらタイマーを取り消す。`pendingTurnText` は保持されているので、
  次の `finalTranscript` で既存の連結ロジックがそのまま繋ぐ
- 猶予中の `state` は **`.listening` を維持**する（`.thinking` にすると「考え中」表示が出て、
  まだ話していいことが伝わらない）。入力終了ジングル `pendingInputEndCue` は
  **commit が確定してから**鳴らす（現行の空セグメント無音化の仕組みをそのまま延長する）
- 空セグメント（ノイズ誤検知）には猶予を挟まない。現行どおり黙って listening へ戻す
- **末尾語で猶予を出し分ける**（`TurnCommitGrace` 新規・純関数）:
  - 接続詞・前置詞・冠詞・be 動詞・助動詞で終わる（`and` `but` `so` `because` `the` `a` `to`
    `of` `I` `was` `is` `my`…）→ **長め 1.6 秒目安**（明らかに続きがある）
  - `.` `?` `!` で終わる完結文 → **短め 0.4 秒目安**（現行に近い応答速度を保つ）
  - それ以外 → **標準 1.0 秒目安**
  - live の STT が句読点を出すかは Phase 2 の実測で確認する。出さないなら末尾語だけで判定する
  - 末尾語判定には確定テキストが要るので、`finalTranscript` 受信時に**残り猶予を調整する**
    （延長 or 即 commit）。タイマー開始は `.speechStopped`、長さの確定は `finalTranscript`

### 2. 回収ウィンドウの延長（②③）

- `TurnBasedVoiceSession` に「直前の user ターンを回収できるか」の判定を持つ:
  - `state == .thinking` → 常に回収可（②）
  - `state == .speaking` かつ再生開始から `redoWindow` 秒以内 → 回収可（③）
  - それ以外 → 回収不可（④の通常 barge-in へ）
- 回収する場合の処理（`recallAssistantTurn()` 新規）:
  - `claudeTask?.cancel()` / `speaker.stopNow()`
  - **`commitAssistantTurn` を呼ばない**（assistant の発言を履歴に一切残さない）。
    ここが通常 barge-in（`onlyBegun: true` で読み上げ済みを残す）との唯一の差
  - 吹き出しを出していたら `.assistantUtteranceRemoved(id:)`（新規イベント）で引っ込める
  - `history.last` が user のままなので、次の commit で `appendUserMessage` が自動連結する
- **回収の確認は通常 barge-in より厳しくする。** ノイズで回収が起きると Chobi の返事が
  消えてしまい、通常の barge-in（返事は残る）より損害が大きい。回収の確定条件は
  「partial が 2 語以上」を**必須**とし、確定テキスト待ちでの回収は認めない
  （間に合わなければ ④ の通常 barge-in に落ちる。＝壊れない側に倒れる）

### 3. ゲートを 3 値にして、AI ターン中は**しきい値を厳しくして開ける**（A3）

- `AudioTapRouter` の `setSpeechGateOpen(_:) -> Bool` を
  `setSpeechGateMode(_:) -> Bool`（`.closed` / `.open(listening)` / `.open(assistantTurn)`）へ広げる
- `.assistantTurn` では `ClientSpeechEndpointer.Thresholds` を厳しい側へ差し替える。ノイズの誤発火は
  **単発・短い**ものが大半なので、効かせどころは主に継続時間:
  - `minimumSpeechDuration` 0.12 → **0.30 秒目安**（咳・物音・キーボードを落とす）
  - `minimumPeak` / `snrRatio` は listening 側の **1.5 倍目安**（読み上げ中は暗騒音の更新が
    止まっている＝比が当てにならないので、絶対値側で効かせる）
  - `silenceDuration` / `lookbackDuration` / `maxSegmentDuration` は共通
- **thinking と speaking を区別する**。thinking は音を出していない＝エコーが無いので listening と
  同じしきい値で開く。厳しくするのは speaking だけ。②の回収がここに乗る
- モードが変わっても**進行中のセグメントは破棄しない**。破棄するのは `.closed` へ落ちるときだけ
  ＝現行の `discardedActiveSegment` → `input_audio_buffer.clear` の導線をそのまま残す

### 4. 割り込みは「確からしい発話」で遅延確定する（④ confirmed barge-in）

- `.speechStarted` を受けても**その場では止めない**。代わりに読み上げを**ダッキング**する
  （出力ゲイン × 0.3 目安）。「聞こえてるよ」の即時フィードバックであり、非破壊
- 確定条件（どれかで割り込み確定）:
  - **partial transcript が 2 語以上** 届いた（ノイズはテキストにならない）
  - もしくは終端後の確定テキストがレベルゲート・エコーフィルタを通過した（保険。遅いが確実）
- 破棄条件（ダッキングを戻して読み上げ継続、チャットには何も出さない）:
  - 終端まで来て確定テキストが空 / レベルゲート棄却 / prompt エコー / **AI 発話のエコー**
- 確定が読み上げ終了に間に合わなかった場合は、既存の `handleTurnFinished` →
  `commitPendingTurnIfReady()` がそのまま次ターンとして投入する（＝案 A4 の挙動）
- ダッキングは `PlaybackVolumePolicy` 由来のシステム音量ゲインと**掛け合わせる**。
  `TurnBasedVoiceSession` にシステムゲインと duck 状態を持ち、`applyPlaybackGain()` の 1 箇所で
  `speaker.setOutputGain(system * duck)` を出す（KVO とダッキングが互いを上書きしないように）
- **4o 経路（サーバ VAD）は従来どおり即時 barge-in のまま**。分岐は
  `configuration.transcription.usesClientEndpointing`

### 5. 自分の読み上げ（エコー）で自滅しない

- 前提は Voice Processing（AEC）有効。`startMicWatchdog()` が VP を切った端末では
  **speaking 中はゲートを閉じる**（＝現行挙動へフォールバック）。VP なしでエコーが素通りする端末で
  常時入力にすると、AI の声で AI が止まる無限ループになる
- `AssistantEchoFilter`（新規・純関数）: 確定テキストと**その時点で読み上げ中だった発話テキスト**の
  トークン重なり率で判定し、閾値以上ならエコーとして破棄する。`STTHallucinationFilter` と同じ層に置く
- 読み上げ中の暗騒音更新停止（既存）はそのまま。停止中はフロアが古いので、3 の絶対値側で守る

### 6. 切り替えとログ（実機で追い込めるようにする）

- 管理画面「音声入力」に**窓モードの切替**を足す: `ターン制（現行）` / `常時（割り込み確認あり）`。
  既定はコード側（`VoiceInputSettingsStore` の規約どおり、既定と同じ選択は保存しない）
- 新しく画面に出す値は**4 つだけ**に絞る（7 項目 × 2 セットにはしない）:
  - 送信猶予（標準）/ 言い直しの窓 `redoWindow` / AI ターン中のしきい値倍率 / AI ターン中の発話開始継続
  - 猶予の長短（0.4 / 1.6 秒）は標準値からの固定比で導出し、画面には出さない
- 会話ログ（管理画面のみ）に 1 行:
  `猶予 1.6 秒（末尾 "the"）` / `言い直しで回収（読み上げ 0.4 秒経過）` /
  `barge-in 確定（partial "so i think"）` / `barge-in 破棄（エコー: 重なり 0.8）` など理由付きで残す

## Phase 構成

- **Phase 1: 送信猶予（①）** ← **ゲートを触らないので単独で入れられ、日常の不満に一番効く**
  （2026-08-04 完了・実機確認済み。下記「Phase 1 実装メモ」）
  - `commitPendingTurnIfReady()` にタイマー、`TurnCommitGrace`（純関数）、猶予中の state 維持、
    ジングルのタイミング調整
  - この時点で「詰まっても続きを言えば 1 つのターンになる」
- **Phase 2: 実測**（コード変更は診断ログのみ）
  - live 経路で **partial delta がセグメント途中に届くか / どれくらい遅れるか**を実機で測る。
    届かないなら③の回収は「partial 2 語以上」を満たせず成立しない（要判断）
  - **確定テキストに句読点が入るか**（猶予の出し分けに使えるか）
  - 読み上げ中のマイク RMS（＝ VP 通過後のエコー残留）を実機で測り、`.assistantTurn` の
    絶対値しきい値の初期値を決める
- **Phase 3: ゲートモード 3 値 + 非対称しきい値**（割り込みはまだしない = 案 A4）
  - `AudioTapRouter` / `syncVoiceInputGate` / `ClientSpeechEndpointer.Thresholds` の派生
  - この時点で「AI が話している間に話しかけると、読み上げ終了後に自分のターンとして入る」
- **Phase 4: 遅延確定 + ダッキング + 回収ウィンドウ（②③④）**
  - `handleSpeechStarted` の分岐、確定判定（純関数）、`applyPlaybackGain()` の集約、
    `recallAssistantTurn()` と `.assistantUtteranceRemoved` イベント
  - ②（thinking 中の回収）は Phase 3 のゲート開放だけで成立するので先に入れて確認できる
- **Phase 5: エコー対策**
  - `AssistantEchoFilter` + VP オフ端末のフォールバック（speaking 中は閉じる）
- **Phase 6: 管理画面（窓モード切替 + 新規 4 項目 + 会話ログ）**
- **Phase 7: 実機総合確認 → 既定の決定 → ドキュメント反映**
  - `CLAUDE.md` の音声レイヤの方針にある「**音声での barge-in は無い**」を更新する
  - `docs/specs/conversation-design.md` の barge-in 仕様に確定条件と回収ウィンドウを反映
  - プランを `docs/plans/archive/` へ移動

Phase 1 は独立で、実機確認して悪ければ猶予 0 に戻すだけで済む。
Phase 3 だけでも「いつでも話せる」体験の大半（話しかけを取りこぼさない）は入る。
Phase 4 以降は「相手が止まる」ぶんの上積みなので、Phase 3 の実機確認で切り分けてから進める。

## Phase 1 実装メモ（2026-08-04）

実装したのは①の送信猶予だけ。ゲート（`AudioTapRouter`）・割り込み・回収には触っていない。

- `Voice/TurnCommitGrace.swift`（新規・純粋な値型）。`standard`（既定 1.0 秒）と
  確定テキストからの出し分けを持つ。長短は**標準からの固定比**で導く
  （続きそう ×1.6 / 完結 ×0.4）。`standard = 0` で従来どおりの即送信に戻る
  - 判定順は「3 点リーダ → `.` `?` `!` → `,` `-` `—` → 末尾語」。live の STT が
    句読点を出さない場合でも末尾語だけで効くようにしてある（Phase 2 の実測待ち）
  - 末尾語のリストには**文末にも普通に立つ語（`you` `it` `that` `there` `some` `well` `yes`）を
    入れていない**。入れると完結した発話まで 1.6 秒待たされ、体感レイテンシがまるごと悪化する
- `TurnBasedVoiceSession`
  - `.speechStopped` で `state = .thinking` に**しなくなった**。`beginCommitGrace(at:)` で
    猶予タイマーを張り、listening のまま追加発話を待つ（＝ live のゲートも開いたまま）。
    従来はここでゲートが閉じるので、ポーズ直後の続きは**入力ごと捨てられていた**
  - `commitPendingTurnIfReady()` が唯一の締めの口。猶予が残っていればタイマーを張り直して return、
    残っていなければ従来どおり commit する。確定テキスト受信時に**残り時間を計算し直す**
    （タイマーの起点は終端の時点なので STT の確定待ちと並行する）
  - 猶予を畳むのは commit 確定 / 追加発話の開始（`.speechStarted`）/ テキスト送信 /
    STT 切断 / `tearDownSTT`。空セグメント（ノイズ誤検知）には猶予を挟まない
  - 入力終了ジングルは従来どおり commit の瞬間に鳴る（猶予ぶん遅れる = 窓が閉じた時刻と一致する）
- 会話ログに 1 行（`送信猶予 1.60 秒（続きそう: "the"）`）。実機で「なぜその長さになったか」を追える
- `TurnMetrics` は変えていない。`committedAt` は終端の時点のままなので、
  **猶予ぶんは `pipelineTotalMs` / `perceivedTotalMs` に乗る**（`sttFinalizeMs` は従来どおり）
- 4o 経路（サーバ VAD）にも同じ猶予がかかる（`commitPendingTurnIfReady()` が経路共通）
- ユニットテスト 12 件（`TurnCommitGraceTests`）。全テスト green・シミュレータビルド確認済み

**2026-08-04 実機で確認して確定**（詰まっても 1 ターンになる / 完結文の応答が遅くなっていない /
ノイズだけのターンは従来どおり無音で通り過ぎる）。既定値は `standard = 1.0` 秒のまま据え置き。
挙動を元へ戻したいときは `commitGrace.standard` を 0 にする。

## Phase 2 実装メモ（2026-08-04）

**測るための計装だけを入れた。音声パスの挙動は 1 つも変えていない**（読むだけ・記録するだけ）。

- `Voice/VoiceInputProbe.swift`（新規・純粋な値型 2 つ）
  - `SegmentTranscriptProbe`: 発話開始を起点に、partial delta の到達時刻と語数・commit・確定を並べる。
    **delta を「commit より前 / 後」で分けて数える**ところが実測 1 の本体
  - `PlaybackEchoProbe`: 読み上げ中のマイク RMS を集計する。平均・最大だけでなく
    **候補しきい値（0.01 / 0.02 / 0.03 / 0.05）ごとの連続超過の最長時間**を持つ。
    エンドポインタは「しきい値超えが連続して `minimumSpeechDuration` 続く」で発火するので、
    この最長時間がそのまま「その設定なら誤発火するか」の答えになる
- `AudioTapRouter`: `beginPlaybackEchoProbe()` / `endPlaybackEchoProbe()`。集計は
  **ゲートの開閉と無関係**にタップの生レベルから行う（＝ AI ターン中にゲートを開けたら
  VAD が何を見ることになるかが、ゲートを開ける前に分かる）
- `TurnBasedVoiceSession`: state が `.speaking` に入る / 出るでエコー計測を開始 / 終了し、
  STT の `.speechStarted` / `.partialTranscript` / `.speechStopped` / `.finalTranscript` に
  セグメント計測をぶら下げる。プローブは `pendingSegmentLevels` と同じ FIFO で持つ
  （STT は commit した順に確定を返すので、delta と確定テキストが別セグメントへ付かない）
- 出力先は**診断ログ**（管理画面「診断ログ」）。会話ログ・トーク画面には出さない
- ユニットテスト 14 件（`VoiceInputProbeTests`）。全 448 件 green・シミュレータビルド確認済み

### 実機での測り方

1. `./run-install-iphone.sh` でインストール（端末はロック解除しておく）
2. 管理画面「診断ログ」を**クリア**してから会話を 1 セッション（3〜5 ターン）
3. 以下を **1 セッションずつ条件を変えて** 3 回: ①イヤフォンなし（本体スピーカー）
   ②イヤフォンあり ③Bluetooth。エコーの乗り方は経路で大きく変わる
4. 診断ログを共有する（`probe stt:` / `probe echo:` の行だけ見ればよい）

### 読み方（どの数字が何を決めるか）

```
probe stt: 発話 2.10s / delta 6 件（初回 +0.85s / 2 語 +1.20s / commit 前 4 件（5 語）・後 2 件）
           / commit→final 0.36s / final 9 語 末尾"."・読点あり 「I went to the park, ...」
probe echo: 読み上げ 4.20s / rms 平均 0.0031 最大 0.0180 / 512 buf / >0.010 0.43s(最長 0.13s)
           / >0.020 0.00s(最長 0.00s) / ... / floor 0.0021 / VP=on / 内蔵スピーカー
```

| 見る数字 | 決まること |
| --- | --- |
| `commit 前 N 件`（0 なら delta は確定と同時） | **③の回収と④の遅延確定が成立するか**。0 件なら「partial 2 語以上」で割り込みを確定できないので、確定テキスト待ち（遅い側）へ倒すか③を落とす |
| `2 語 +X.XXs` | ④の割り込み確定までの体感待ち時間。ここが 1 秒を超えるなら `redoWindow` を 1 秒から伸ばす |
| `commit→final` | ①の送信猶予のうち、STT 確定待ちと並行して食える時間（純増ぶんの見積り） |
| `末尾"."・読点あり / 末尾記号なし` | 猶予の出し分け（`TurnCommitGrace`）が記号で効くか、末尾語だけが頼りか |
| `>0.0XX ...(最長 Y.YYs)` | Phase 3 の `.assistantTurn` のしきい値。**最長が `minimumSpeechDuration`（0.30 秒案）を超えないしきい値**が下限。全しきい値で最長 0.00s ならエコーは実質無害 |
| `floor` と `rms 平均` の差 | 読み上げ中に暗騒音がどれだけ持ち上がって見えるか（比での判定が当てにならない度合い） |
| `VP=off` の行 | その端末・経路では speaking 中にゲートを閉じるフォールバックが要る（Phase 5） |

### 実測結果

（実機での収集待ち。ここに 3 経路ぶんの代表値と、上の表に沿った判断を書く）

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Voice/TurnBasedVoiceSession.swift` | 送信猶予のタイマー、`recallAssistantTurn()`、`syncVoiceInputGate` のモード判定、`handleSpeechStarted` の遅延確定、ダッキングとシステム音量ゲインの集約、エコー判定の適用、診断ログ |
| `Voice/TurnCommitGrace.swift`（新規・Phase 1 済） | 確定テキストの末尾から猶予の長さを決める純関数 |
| `Voice/VoiceInputProbe.swift`（新規・Phase 2 済） | 実測用のプローブ 2 種（診断ログへ 1 行。挙動は変えない） |
| `Voice/MicrophoneCapture.swift`（`AudioTapRouter`） | ゲートを 3 値化、モードごとのしきい値差し替え |
| `Voice/ClientSpeechEndpointer.swift` | `Thresholds` から AI ターン用の派生を作る（純関数） |
| `Voice/VoiceSession.swift` | `.assistantUtteranceRemoved(id:)` イベントの追加 |
| `Voice/CloudPipeline/OpenAITranscriptionProtocol.swift` | `AssistantEchoFilter` の追加（`STTHallucinationFilter` と同じ層） |
| `Conversation/ChatRoomStore.swift` | 吹き出しの取り消し処理、新しい設定をセッション `Configuration` へ詰める |
| `Settings/VoiceInputSettingsStore.swift` / `Admin/VoiceInputSettingsView.swift` | 窓モードと新規 4 項目の保存・UI |
| `CLAUDE.md` / `docs/specs/conversation-design.md` | barge-in 仕様と回収ウィンドウの更新（Phase 7） |

- **4o 経路（常時入力 + サーバ VAD + 即時 barge-in）は変更しない**
  - ただし Phase 1 の送信猶予は経路共通の `commitPendingTurnIfReady()` に入るため、4o でも効く。
    4o は即時 barge-in なので②③の回収は入れない（猶予①だけ共有する）
- 保存データ・会話履歴のスキーマ変更なし
- STT 課金は AI ターン中に発話区間が増えるぶんだけ増える（分課金 $0.017/分。誤発火が減っていれば
  実質ほぼ増えない）
- Claude 課金は回収で捨てたターンぶん増える。system prompt はキャッシュ読みなので入力は安く、
  出力も 1 秒ぶんで止まる。頻度は低い想定

## テスト方針

- **ユニット**（純粋な値型に寄せて書けるところを増やす）
  - `TurnCommitGrace`: 接続詞・冠詞で終わる → 長い / 句点で終わる → 短い / 空文字の扱い
  - `ClientSpeechEndpointer`: AI ターン用しきい値で短い物音が発話開始にならないこと / 本人の声は通ること
  - `AudioTapRouter`: モード遷移（listening → assistantTurn で進行中セグメントを破棄しない、
    `.closed` では従来どおり破棄して true を返す）
  - `AssistantEchoFilter`: AI の直前発話と同文 → エコー、似た単語を含む正当な発話 → 通す
  - 回収可否の判定（thinking / speaking + 経過時間）と割り込み確定（partial の語数）を
    純関数に切り出して境界値
- **シミュレータ**: 既存の全テスト + テキスト会話の回帰（音声パスは対象外）
- **実機**（本タスクの本丸）
  1. 途中で 1 秒ほど詰まっても、続きを言えば**1 つのターン**として送られること
  2. 言い終わった直後に「あ、違う」と言い直すと、Chobi の返事が消えて言い直しごと送られること
  3. 完結文（`.` で終わる）のターンで、応答が体感で遅くなっていないこと
  4. AI の読み上げ中に話しかけると、読み上げが小さくなり → 止まり → 自分のターンになること
  5. 読み上げ中に咳・物音・キーボードを立てても、読み上げが**切れない**こと（回収も起きない）
  6. テレビ / 家族の声が鳴っている部屋で黙っていて、ターンが commit されないこと
  7. イヤフォンなし（本体スピーカー）でも AI の声で自滅しないこと。VP が切れた端末では
     speaking 中に入力が閉じること
  8. thinking 中（無音の待ち時間）に話しかけたぶんが取りこぼされないこと
  9. 管理画面の会話ログに、猶予の長さ・回収・割り込みの確定 / 破棄が理由付きで残ること

## 見送り・エスカレーション先

- **PTT（押している間だけ聞く）/ 取り消しボタン / 割り込み専用ボタン**: 確実だが
  「操作は声だけ」という方針（2026-08-04）に反する。最終手段
- **`silenceDuration` を伸ばすだけで済ませる**: 全ターンが遅くなり STT 課金も伸びるので却下
  （B1）。ただし Phase 1 が期待外れだった場合の退避先ではある
- **声紋・話者識別で本人だけ通す**: Realtime transcription では
  `known_speaker_references[]` を使えない（`noise-input-rejection.md` 調査 #9）。API が開放されたら本命
- **ML VAD（Silero 等を CoreML で）へ差し替え**: エネルギー VAD が限界だと分かった場合の
  エスカレーション先。`ClientSpeechEndpointer` の差し替えで済む形は既に保てている
- **4o + サーバ VAD へ戻す**: 誤爆の原因だったので戻さない（切替経路としては維持）

## 未確認・リスク

- **partial delta の到達タイミング**（Phase 2 で測る）。セグメント確定後にまとめて届く実装だと、
  ③の回収に必要な「partial 2 語以上」が読み上げ開始 1 秒以内に間に合わない。その場合は
  `redoWindow` を伸ばす（2〜3 秒）か、③を諦めて②までにする
- **確定テキストの句読点**（Phase 2 で測る）。出ないなら猶予の出し分けは末尾語だけになる
- **猶予による体感レイテンシの悪化**。STT 確定待ちと並行させても純増ぶんは残る。
  完結文を短い猶予にする出し分けが効かないと、全ターンが 1 秒近く遅くなる
- **猶予の再武装が続くと送信が伸びる**（Phase 1 で入った挙動）。VAD が発火するたびに
  猶予を張り直すので、テレビ等で VAD が鳴り続ける部屋では 1 ターンの送信が遅れ続けうる。
  ただし「発話中・確定待ちのあいだは commit しない」のは元からの条件で、猶予はそこに
  1.6 秒足すだけ。総待ち時間に上限を置くかは Phase 7 の実機確認で判断する
- **VP のエコー除去性能**が端末・経路（本体スピーカー / Bluetooth）で大きく変わる。
  Bluetooth HFP では特に厳しい可能性があり、経路ごとにゲートを閉じる判断が要るかもしれない
- ダッキングと `PlaybackVolumePolicy` の掛け合わせで、**音量下限（0.05 以下は無音）**の扱いが
  二重にならないよう注意する（`docs/plans/archive/tts-volume-not-following.md`）
- **回収の誤爆**が最悪ケース。Chobi の返事が理由もなく消えるのは体験として最悪なので、
  疑わしいときは回収しない（＝通常 barge-in か、何もしない）側へ倒す
