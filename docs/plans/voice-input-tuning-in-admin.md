# 音声入力のしきい値を管理画面で調整する

## 目的・背景

声を出していないのにクライアント VAD が発話開始と判定することがある
（`docs/plans/empty-segment-no-cue.md` で「空だったターンは無音で通す」対応は入れたが、
**誤検知そのものの頻度は閾値次第**）。逆に閾値を上げすぎると本人の発話を取りこぼす。

適正値は部屋の暗騒音・マイク・声量で変わるため、コードを書き換えて再インストールする
ループでは追い込めない。**実機で数値を動かして次のセッションで試せる**ようにする。

調整対象は 2 つの構造体で、いまはどちらもコード既定のまま `launchSession` に渡っている。

- `ClientSpeechEndpointer.Thresholds`（発話の検知。live 経路のクライアント VAD）
- `SpeechLevelGate.Thresholds`（認識後の棄却。暗騒音と大差ないセグメントを捨てる）

## 決定事項（2026-08-03）

- 出す項目は**音声入力の一式 7 項目**（`ClientSpeechEndpointer.Thresholds`）。
  レベルゲート側の音量しきい値 3 つは**同じ値を共有する**（既定値も同一で、コード上も
  「`SpeechLevelGate.Thresholds` の実機調整値を流用」と書かれている関係のため）。
  `SpeechLevelGate.minimumSampleCount` は出さない（既定 3 のまま）
- 反映は**次のセッションから**（モデル設定と同じ。セッション中に基準がぶれない）
- 調整の手がかりとして、**直近セグメントの実測値を画面に出す**（peak / floor / 比 / 採否 / 本文）

### 項目・範囲・刻み

| 表示名 | フィールド | 既定 | 範囲 | 刻み |
| --- | --- | --- | --- | --- |
| 発話とみなす音量 | `minimumPeak` | 0.010 | 0.002〜0.050 | 0.002 |
| 暗騒音への倍率 | `snrRatio` | 3.0× | 1.5〜8.0 | 0.5 |
| 無条件で採用する音量 | `unconditionalPeak` | 0.050 | 0.020〜0.200 | 0.010 |
| 発話開始の継続 | `minimumSpeechDuration` | 0.12 秒 | 0.04〜0.50 | 0.02 |
| 無音での終端 | `silenceDuration` | 0.80 秒 | 0.30〜2.00 | 0.10 |
| 語頭の遡り | `lookbackDuration` | 0.50 秒 | 0.00〜1.50 | 0.10 |
| 強制終端 | `maxSegmentDuration` | 60 秒 | 15〜180 | 15 |

閾値は `min(max(暗騒音 × snrRatio, minimumPeak), unconditionalPeak)` なので、
`unconditionalPeak < minimumPeak` にすると下限が効かなくなる。範囲では防げないため、
その組み合わせのときは画面に注意書きを出す（保存自体は許す）。

## 対応方針

### Phase 1: 設定の保存（`Settings/VoiceInputSettingsStore.swift`）

- `VoiceInputParameter`（7 項目の enum。表示名・説明・範囲・刻み・書式・`Thresholds` への
  読み書きを 1 箇所に持つ）と `VoiceInputSettingsStore` を追加する
- `ModelSettingsStore` と同じ規約: **既定値はコード（`ClientSpeechEndpointer.Thresholds()`）が正**、
  既定と同じ値は保存しない（あとで既定を変えたら追従する）。保存は UserDefaults、
  キーは `voiceInput.<フィールド名>`
- 範囲外の保存値は読み出し時に clamp する（手で書き換えた値・範囲を狭めた場合の保険）
- `thresholds()` / `levelGateThresholds()` でセッション設定へ渡す形に組み立てる

### Phase 2: 管理画面「音声入力」（`Admin/VoiceInputSettingsView.swift`）

- `AdminView.Tab` に `.voiceInput = "音声入力"` を足し、「設定」セクションへ入れる
  （ルートの右肩サマリは「既定」/「N 項目変更」）
- 音量 / 時間の 2 セクション + `Stepper` で編集。footer に各項目の説明と既定値を出す
- 「すべて既定に戻す」ボタン（既定のままなら無効）

### Phase 3: セッションへの反映（`ChatRoomStore.launchSession`）

- `configuration.clientEndpointer` / `configuration.levelGate` に詰める
- 既定から変えているときだけ診断ログへ 1 行残す（あとから「どの閾値のセッションか」を辿る）

### Phase 4: 直近セグメントの実測表示

- `VoiceSessionEvent` に `.segmentMeasured(SpeechSegmentMeasurement)` を足し、
  いま `.info("STT セグメント …")` で流している内容を**構造化したまま**渡す
  （会話ログの 1 行は `ChatRoomStore` 側で同じ文面を組み立てるので出力は変わらない）
- `VoiceInputSettingsStore` が直近 20 件をリングバッファで保持する（UserDefaults に JSON。
  アプリを再起動しても残る）。設定と同じ画面でしか使わないので型は分けない
- 画面下部のセクションに新しい順で並べる（採否・peak / floor / 比・本文）

### Phase 5: 環境ごとのプリセット（2026-08-03 追加）

7 項目を個別に動かすのは調整の最終手段で、普段は**部屋の状況で丸ごと切り替えたい**。
「静かな部屋」「生活音のある部屋」「外・カフェ」の 3 つを用意し、1 タップで全項目を入れる。

| 項目 | 既定 | 静かな部屋 | 生活音のある部屋 | 外・カフェ |
| --- | --- | --- | --- | --- |
| 発話とみなす音量 | 0.010 | 0.012 | 0.016 | 0.024 |
| 暗騒音への倍率 | 3.0× | 3.0× | 4.0× | 5.0× |
| 無条件で採用する音量 | 0.050 | 0.050 | 0.060 | 0.080 |
| 発話開始の継続 | 0.12 秒 | 0.16 秒 | 0.20 秒 | 0.24 秒 |
| 無音での終端 | 0.80 秒 | 0.80 秒 | 0.80 秒 | 0.70 秒 |
| 語頭の遡り | 0.50 秒 | 0.50 秒 | 0.50 秒 | 0.50 秒 |
| 強制終端 | 60 秒 | 60 秒 | 45 秒 | 30 秒 |

- 暗騒音が上がるほど「絶対値の下限」と「倍率」を上げ、単発の物音を弾くために発話開始の継続も
  伸ばす。騒がしい場所は終端が出にくいので強制終端を短くする
- **どのプリセットも既定値とは一致させない**（既定は既定として「すべて既定に戻す」で戻す）。
  プリセットは選択状態を持たず、**現在値が一致していればチェックを付ける**だけにする
  （「カスタム」という 4 つ目の状態を作らない）
- 全項目が範囲内かつ刻みに乗っていることをテストで担保する（画面の Stepper と食い違わない）

## 影響範囲

- 追加: `Settings/VoiceInputSettingsStore.swift`、`Admin/VoiceInputSettingsView.swift`、
  対応するテスト
- 変更: `Admin/AdminView.swift`（項目追加）、`Conversation/ChatRoomStore.swift`（注入と反映・
  `.segmentMeasured` の処理）、`Voice/VoiceSession.swift`（イベント追加）、
  `Voice/TurnBasedVoiceSession.swift`（`.info` → `.segmentMeasured`）、
  `Voice/SpeechLevelGate.swift`（`Codable` 適合と計測 1 件の型）
- 4o 経路（サーバ VAD）は `clientEndpointer` を使わないため、時間 4 項目は効かない。
  レベルゲート（音量 3 項目）は両経路で効く。画面の注記に書く
- `SegmentLevelMeter.lookbackWindow`（暗騒音メータ側の遡り 12 バッファ）は別物なので触らない

## テスト方針

- `VoiceInputSettingsStoreTests`: 既定は保存しない / 再読込で残る / 範囲外の clamp /
  `resetToDefaults` / `thresholds()` と `levelGateThresholds()` の組み立て /
  リングバッファが 20 件で頭から落ちること
- `AdminViewTests`: 既存の「全 Tab がちょうど 1 回」「rawValue の並び」を更新
- `xcodebuild` でビルド + 全テスト
- 実機確認: 閾値を上げたセッションで誤検知が減るか / 実測値の一覧が更新されるか /
  取りこぼし（発話の頭切れ）が出ていないか
