# 端末のボリュームを下げても読み上げ音量が下がらない

## 目的・背景

会話セッション中、iPhone のボリュームボタンで音量を下げても Chobi / Naruko の読み上げが
鳴り止まない。実機でしか再現しないため、まず**どこで音量が握られているか**を
確定させてから直す。

## 現状の構成（コードから確認した事実）

会話セッションの音声まわりは以下のようになっている。

| 要素 | 実装 | 場所 |
| --- | --- | --- |
| AVAudioSession | `.playAndRecord` / `mode: .voiceChat` / options = `AudioRoutePolicy.categoryOptions` | `TurnBasedVoiceSession.start()` L291 |
| 出力経路 | 本体内蔵のみのとき `overrideOutputAudioPort(.speaker)` | `applyOutputRoute()` L936 |
| 読み上げ再生 | **専用の AVAudioEngine**（`player` → `mainMixerNode`）。VP なし | `StreamingAudioPlayer` |
| マイク入力 | **別の AVAudioEngine**。`inputNode.setVoiceProcessingEnabled(true)` | `MicrophoneCapture.start()` L288 |

つまり **1 つの AVAudioSession の上で AVAudioEngine が 2 つ動き、片方（入力）だけが
Voice Processing I/O（VPIO）**という構成になっている。

起動順は以下のとおり。

```
setCategory(.playAndRecord, .voiceChat) → setActive(true)
  → applyOutputRoute()  … overrideOutputAudioPort(.speaker) はここ
  → speaker.prepare()   … 再生エンジン start
  → connectSTT() → ready → startMicrophoneStreaming()
      → microphone.start(voiceProcessing: true)  ← VPIO はいちばん最後に有効化される
```

## Phase 0: 診断（完了 2026-08-03）

`AVAudioSession.outputVolume` を KVO で監視し、カテゴリ・モードと一緒に診断ログへ出した
（`startVolumeObserver()` / `describeVolume()`）。あわせて経路ログにも音量を載せた。

### 実機の測定結果

```
route: 開始 出力=Receiver(レシーバー) …
route: 開始 outputVolume=0.90 category=…PlayAndRecord mode=…VoiceChat   ← 受話口のときは 0.90
route: 出力を スピーカー へ切り替えた
volume: outputVolume=0.05 …                                            ← override 直後に 0.05 へ
volume: outputVolume=0.90 …
volume: outputVolume=0.05 …                                            ← 0.05 で落ち着く

（ボリュームアップ）0.05 → 0.15 → 0.20 → 0.25 → 0.30
（ボリュームダウン）0.30 → 0.25 → 0.20 → 0.15 → 0.05   ← ここで止まる。0.00 にならない
（ボリュームアップ）0.05 → 0.15 → 0.20 → 0.30 → 0.40 → 0.45
```

作者の体感は「上げると大きくなる／下まで下げてもまだ鳴っている」。

### 読み取れること

1. **再生レベルは `outputVolume` に追従している。** 上げれば大きくなり、下げれば小さくなる。
   → **H1（VPIO が出力レベルを握って音量を無視する）は否定**。VPIO のワークアラウンド
   （`overrideOutputAudioPort` の打ち直し）は不要
2. **下限が 0.05 で、0.00 に到達しない。** 何度押しても 0.05 で止まり、そこでも鳴り続ける
   → **H3 が確定**。`.playAndRecord` + `mode: .voiceChat` の組み合わせで**通話音量チャンネル**
   として扱われており、通話と同じく「ボタンでは消音できない」挙動になっている
3. **出力経路ごとに音量の記憶が別。** 受話口では 0.90、スピーカーへ override した瞬間 0.05 へ
   飛ぶ。セッション開始直後の 1 発目の音量が前回の続きにならないのはこのため
4. 刻みは概ね 0.05（20 段階）。メディア音量の 16 段階（0.0625 刻み）ではない ―― これも
   通話音量チャンネルであることの傍証。KVO は連打すると間引かれる（0.10 が記録されない等）

### 判定

| 仮説 | 判定 |
| --- | --- |
| H1: VPIO が出力レベルを握る | **否定**（音量に追従している） |
| H2: カテゴリごとの音量記憶のズレ | 部分的に該当（経路ごとに別。ただし主因ではない） |
| H3: `mode: .voiceChat` の副作用 | **確定**（下限 0.05 の床 = 通話音量チャンネル） |


## Phase 1-A（却下）: `mode` を `.default` にする

通話音量チャンネルから外れればメディア音量として 0.00 まで下がる、という読みで
live 経路（クライアント VAD = 音声 barge-in が無い経路）だけ `mode: .default` にした。

**実機で却下。** 音量は狙いどおり下がるようになったが、**`.voiceChat` の AGC が外れて
マイクの入力レベルが激減した**（画面下の入力ゲージがほとんど振れない）。
`minimumPeak=0.016` などの調整済みしきい値が丸ごと合わなくなるため、入力を犠牲にする
この方向は取らない。`mode` は `.voiceChat` に戻した。

→ この教訓は CLAUDE.md の音声レイヤの項へ「**`mode: .voiceChat` を `.default` に変えない**」
として書き込んだ。

## Phase 1-B（採用）: 出力側のソフトウェアゲインで床を潰す

`mode` は `.voiceChat` のまま、`StreamingAudioPlayer` の `mainMixerNode.outputVolume` に
ゲインを掛けて下限 0.05 のぶんを打ち消す。

### 実装

| ファイル | 内容 |
| --- | --- |
| `Voice/PlaybackVolumePolicy.swift`（新規） | 純関数のゲインカーブ |
| `TurnBasedVoiceSession.startVolumeObserver()` | `outputVolume` の KVO でゲインを算出し読み上げへ反映 |
| `StreamingAudioPlayer.setOutputGain(_:)` | ミキサへ適用。`prepare()` で再適用（経路変更の再起動対策） |
| `CloudSentenceSpeaker.setOutputGain(_:)` | 中継 |

再読み上げ（`UtteranceReplayer`）は `.playback` = メディア音量なのでゲイン 1.0 のまま。
会話セッションだけがカーブに従う。

### カーブ（実機フィードバックで 1 度調整した）

初版は振幅の線形補間（floor 0.05 → taperEnd 0.20）にしたが、**下限の 1 段上が
いきなり -9.5dB（振幅 1/3）になり「まだ大きすぎる」**という結果だった。
**dB 直線**に変え、絞る範囲も 0.50 まで広げた。

| outputVolume | 0.05 | 0.10 | 0.15 | 0.20 | 0.30 | 0.40 | 0.50〜 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| dB | 無音 | -35.6 | -31.1 | -26.7 | -17.8 | -8.9 | 0 |
| ゲイン | 0.00 | 0.017 | 0.028 | 0.046 | 0.13 | 0.36 | 1.00 |

- 0.05（下げ切った位置）で無音 ＝ 元の要望
- 0.50 以上は素通しなので、普段使う音量域の聞こえ方は変えない
- 調整点は `minimumDecibels`（-40dB。下げるほど 1 段目が小さい）と `taperEnd`（0.5。
  上げるほど絞る範囲が広がる）

### 副作用として受け入れたこと

セッション開始時、スピーカー経路の記憶音量が 0.05 のままだと**いきなり無音で始まる**。
仕様どおりだが「壊れた」と誤解しやすいので、診断ログに `gain=0.0` を残して後から
追えるようにしてある。

## 結果

実機で確認して問題なし（2026-08-04）。ボリュームを下げ切ると無音になり、
1 段上げると小音量として使える。入力ゲージも元どおり。

## テスト

- `PlaybackVolumePolicyTests` 8 件（下限で無音 / 素通し域 / dB 直線 / 単調増加 /
  1 段上が振幅 5% 未満 / 範囲外入力）
- 全体パス（XCTest 421 件 + swift-testing 20 件）

## 残ったもの

- Phase 0 で入れた `outputVolume` の KVO は**そのまま本番の駆動元**になった（診断用ではない）
- 診断ログの `volume:` 行と、経路ログの `outputVolume=` は残してある。
  出力経路ごとに音量の記憶が別（受話口 0.90 → スピーカー 0.05）という挙動は
  今後も紛らわしいので、経路とセットで見える形を保つ
- 却下した保険（管理画面にアプリ内音量スライダー）は**未実装**。ハードボタンの 0.05 刻みで
  足りなくなったら実装する
