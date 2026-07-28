# イヤフォン（AirPods 等）で音が出るようにする

## 目的・背景

実機で AirPods を接続して会話すると、**AI の読み上げが AirPods から出ず内蔵スピーカーから鳴る**。
イヤフォンで練習できないと外出先・家族のいる場所で使えず、日常的に発話量を稼ぐという第一目的に直接効く。

- 症状（実機・ユーザー確認済み）: AirPods 等 Bluetooth で **音が出ない / 内蔵スピーカーから出る**
- マイク（AirPods 側で拾えるか）は**未検証**。本タスクで併せて確認する
- 有線イヤフォンは未検証

## 原因（SDK ヘッダで確定。iPhoneOS26.5.sdk `AVAudioSessionTypes.h`）

現在の設定は `TurnBasedVoiceSession.start()`:

```swift
try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
```

ヘッダの記述と突き合わせると、Bluetooth の**出力**が有効になる経路がひとつも無い。

| 設定 | ヘッダの記述 | 効果 |
| --- | --- | --- |
| `mode: .voiceChat` | 「Has the side effect of setting `AllowBluetoothHFP`」 | HFP が**入力**の候補として現れる |
| `AllowBluetoothHFP`（暗黙 ON） | PlayAndRecord では「a paired bluetooth HFP device to appear as an available route **for input**, while playing through the **category-appropriate output**」 | 出力は「カテゴリ既定の出力」のまま |
| `AllowBluetoothA2DP` | 未設定。PlayAndRecord では「defaults to **false**」 | Bluetooth の**出力**ポートが候補にすら現れない |
| `.defaultToSpeaker`（明示 ON） | 「routing to **Speaker** (instead of Receiver)」 | カテゴリ既定の出力＝内蔵スピーカーに固定される |

つまり **「入力は AirPods・出力は内蔵スピーカー」という観測結果とちょうど一致する**。
`.defaultToSpeaker` はヘッダ上「no other audio route is connected」のときの既定と書かれているが、
実運用では Bluetooth と併用すると出力をスピーカーへ引き寄せることが知られており、
いずれにせよ A2DP 未許可のままでは Bluetooth 出力は選ばれない。

## 対応方針

### 方針 1: 経路ポリシーを「静的オプション」から「動的オーバーライド」へ変える（本命）

`.defaultToSpeaker` を**カテゴリオプションから外し**、代わりに
「**出力が内蔵レシーバー（受話口）しか無いときだけ** `overrideOutputAudioPort(.speaker)` する」形に置き換える。
イヤフォン・Bluetooth・AirPlay が繋がっていればオーバーライドしない（＝ OS の選んだ経路に任せる）。

```swift
try session.setCategory(
    .playAndRecord, mode: .voiceChat,
    options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay])
// setActive 後と経路変更のたびに再評価
try session.overrideOutputAudioPort(needsSpeaker ? .speaker : .none)
```

- `.allowBluetoothHFP` は `.voiceChat` で暗黙 ON だが、**依存を明示**して読み手に意図を残す
- `.allowBluetoothA2DP` を足すのはマイクを持たない Bluetooth スピーカー / ヘッドホンのため。
  AirPods のように HFP と A2DP の両方を持つ機器は、ヘッダ記載どおり **HFP が優先**されるので
  「マイクも AirPods」という望ましい形は保たれる（会話アプリなので HFP 優先でよい）
- 音質は HFP（AirPods は mSBC 16kHz）に落ちるが、**マイクとの同時使用が必須**な以上これは避けられない。
  出力専用の高音質（A2DP）を選ぶとマイクが内蔵に戻り、口元から離れるので採らない

判定は純関数に切り出してテスト可能にする（ハードウェア不要）:

```swift
enum AudioRoutePolicy {
    static func needsSpeakerOverride(outputPortTypes: [AVAudioSession.Port]) -> Bool
}
```

### 方針 2: 経路を診断ログと会話ログに出す（原因確定と再発時の一撃特定）

いまはどの経路が選ばれたかを知る手段が無く、実機で「鳴らない」以上の情報が取れない。

- セッション開始時（`setActive(true)` 直後）と**経路変更のたび**に、
  `currentRoute` の入出力ポート（種別 + 名前）とサンプルレートを `DiagnosticsLog` へ 1 行残す
- 同じ内容を `.info` イベントとして会話ログにも出す（実機でその場で読める）
- 既存の `!!` 接頭辞の慣習に合わせ、オーバーライドの適用も記録する

### 経路変更ハンドリングの調整

`handleRouteChange` は現在 `.oldDeviceUnavailable` / `.newDeviceAvailable` でのみ I/O を再起動している。

- **どの理由でも**オーバーライドの再評価は行う（イヤフォン接続時に確実に効かせる）
- I/O 再起動の条件は従来どおり 2 つの理由のまま変えない
- `overrideOutputAudioPort` 自身が `.override` 理由の経路変更を発火するため、
  **必要な値が現在と変わるときだけ呼ぶ**（無限ループ防止）。`.override` では I/O を再起動しない

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Voice/AudioRoutePolicy.swift`（新規） | 経路判定の純関数 + 経路の要約文字列化 |
| `Voice/TurnBasedVoiceSession.swift` | カテゴリオプション変更・オーバーライド適用・経路ログ・`handleRouteChange` |
| `EslSpeakingCoachTests/AudioRoutePolicyTests.swift`（新規） | 判定の単体テスト |
| `docs/specs/`（必要なら） | 音声経路の仕様追記 |

シミュレータ経路（`#if targetEnvironment(simulator)`）は `.playback` のままで変更しない。

## テスト方針

- **ユニット**: `AudioRoutePolicy.needsSpeakerOverride` を経路パターン（レシーバーのみ / ヘッドホン /
  Bluetooth HFP / A2DP / スピーカー / 空）で検証。既存 176 件を含め全パス
- **ビルド**: `xcodegen generate` + `xcodebuild`（シミュレータ）
- **シミュレータ E2E**: テキスト入力の会話フローが退行していないこと（音声経路自体は検証不可）
- **実機（必須）**:
  1. AirPods 接続状態で会話開始 → **AI の声が AirPods から鳴る**
  2. AirPods のマイクで発話 → STT が認識する
  3. 会話中に AirPods を接続 / 切断 → 経路が追随し会話が続く
  4. イヤフォン無しで会話 → 従来どおり内蔵**スピーカー**（受話口ではない）から鳴る ← 退行チェック
  5. 有線イヤフォン（USB-C）でも 1・2 が成立する
  6. 診断ログに経路の行が残っている

## Phase

- [x] **Phase 1: 経路ポリシーと診断ログ** — `AudioRoutePolicy` 新設、カテゴリ設定の置き換え、経路ログ
- [x] **Phase 2: 経路変更の追随** — `handleRouteChange` でのオーバーライド再評価とループ防止
- [x] **Phase 3: テスト・ビルド・シミュレータ確認**
- [x] **Phase 4: 実機確認（上記チェックリスト）・仕様同期・後片付け**

## 実施記録

### Phase 1〜3（2026-07-28）

- `Voice/AudioRoutePolicy.swift` を新設。`categoryOptions`（`.allowBluetoothHFP` /
  `.allowBluetoothA2DP` / `.allowAirPlay`。**`.defaultToSpeaker` は入れない**）、
  純関数 `needsSpeakerOverride(outputPortTypes:)`、ログ用の `describe(_:sampleRate:)` を置いた
- `TurnBasedVoiceSession`:
  - `setCategory` のオプションを `AudioRoutePolicy.categoryOptions` に差し替え
  - `applyOutputRoute(context:)` を追加。経路を診断ログ + `.info` イベントへ出し、
    `needsSpeakerOverride` が true のときだけ `overrideOutputAudioPort(.speaker)` する。
    **直近の適用値（`currentOutputOverride`）と同じなら呼ばない**
  - 呼ぶのは「開始（`setActive` 直後）」「再開（`resume`）」「経路変更」の 3 点。
    経路変更では `.override` 理由のときだけ再評価を飛ばす（自分が起こした通知でループしないため）
  - I/O 再起動の条件（`.oldDeviceUnavailable` / `.newDeviceAvailable`）は**変えていない**
  - シミュレータ経路（`.playback`）でも経路の記録だけは行う（判定は必ず `.none` になる）
- `AudioRoutePolicyTests` 10 件を追加。**全 186 件パス**（既存 176 + 新規 10）
- シミュレータ E2E: テキスト入力の会話フローに退行なし（学習者ファーストの第一声 →
  Naruko / Chobi の返しまで確認）。診断ログに
  `route: 開始 出力=Speaker(Speaker) 入力=なし 48000Hz` が残ることを確認
- `CLAUDE.md`「音声レイヤの方針」に経路ポリシーの決定を追記

### Phase 4（2026-07-28）

**実機で動作を確認した**（ユーザー確認）。`.defaultToSpeaker` を外し `.allowBluetoothA2DP` を
足したことで、症状（AirPods を繋いでも出力が内蔵スピーカーへ固定される）は解消した。

再発時の調べ方: 診断ログ（管理画面 📊 →「診断」タブ）の `route:` 行に、
どのポートが選ばれたか・スピーカーへオーバーライドしたかが 1 行で残っている。
