# Chobi の読み上げが遅い — 調査と対応

## 目的・背景

実機での会話中、**Chobi の声がゆっくりすぎる**（間延びして聞こえる）。
会話のテンポが落ちると学習者の発話の番が遠のくので、第一目的（発話量）にも効く。

原因を切り分けて、直せる場所（voice / スタイル前置文 / 再生側）を特定する。

> 最初の依頼は「Naruko が遅い」だったので調査は Naruko を主対象に始めたが、**実測では
> Naruko のほうが速く**（Chobi 2.68 / Naruko 2.84 w/s）、その後ユーザーから「対象は Chobi」と
> 訂正があった。測定結果は両キャラぶんあるのでそのまま残し、対応は Chobi に対して行う。

## 現状（コードの事実）

| 項目 | 現状 | 場所 |
| --- | --- | --- |
| Chobi の voice | `Leda` + 「warm, calm, gently cheerful ... friendly teacher」 | `Conversation/ChatCharacter.swift:36` |
| Naruko の voice | `Aoede` + 「bright, energetic ... enthusiastic student」 | `ChatCharacter.swift:43` |
| TTS リクエスト | `speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName` + **テキスト先頭にスタイル前置文** | `Voice/CloudPipeline/GeminiTTSClient.swift:50` |
| 速度パラメータ | **無い**（Gemini TTS は速度の数値指定を持たず、話し方は自然文の指示で制御する） | 同上 |
| 再生 | 24kHz PCM16 → Float32 で `AVAudioPlayerNode`。**キャラによる分岐なし** | `Voice/CloudPipeline/StreamingAudioPlayer.swift:21` |

再生経路が 2 キャラ共通なので、**サンプルレート取り違え（全体が遅く低く聞こえる類）ではない**
（それなら Chobi も同じだけ遅くなる）。残る容疑者は voice そのものと、スタイル前置文。

## 切り分けの方針

同じ文を条件だけ変えて合成し、**音声の長さ（= 話速）を実測**して比べる。
主観ではなく秒数で比べる（24kHz PCM16 mono = 48,000 bytes/秒なので、PCM のバイト数から出せる）。

| # | voice | スタイル前置文 | 狙い |
| --- | --- | --- | --- |
| A | Leda | Chobi 用 | 現行 Chobi（基準） |
| B | Aoede | Naruko 用 | 現行 Naruko（問題の条件） |
| C | Leda | Naruko 用 | 差が **voice** 由来か（同じ指示で voice だけ変える） |
| D | Aoede | Chobi 用 | 差が **前置文** 由来か（同じ voice で指示だけ変える） |
| E | Aoede | Naruko 用 + 速さの指示 | 前置文で直せるか |
| F | 他の voice 数種 | Naruko 用 + 速さの指示 | voice を替える必要があるか |

- 文は実際の Naruko の発話を使う（`Oh, I never get around to washing my dishes right away, they just sit there!`）
- 各条件で 1 回ずつ合成し、秒数と words/sec を出す。ばらつきが疑わしい条件は 2 回目を取る
- 判定は **A（Chobi）と同等以上の words/sec** を目標にする

## 調査結果（2026-07-28 実測）

Gemini TTS を直接叩いて音声を取得し、PCM のバイト数から秒数を出した
（24kHz PCM16 mono = 48,000 bytes/秒）。前後の無音を除いた**発話区間**でも測っている
（無音の混入と話速そのものを分けるため）。スクリプトと wav はセッションの作業ディレクトリに置いた。

**(1) 話速を決めているのは voice ではなくスタイル前置文**（同じ文・3 回平均・発話区間ベース）

| 条件 | w/s |
| --- | --- |
| A Leda + Chobi 用（現行 Chobi） | 2.86 |
| B Aoede + Naruko 用（現行 Naruko） | **3.24** |
| C Leda + Naruko 用 | 3.24 |
| D Aoede + Chobi 用 | 2.89 |

voice を入れ替えても前置文が同じなら話速はほぼ同じ（A≒D、B≒C）。
**つまり Aoede が遅いのではない。**

**(2) Naruko は Chobi より遅くない。実セッションの発話でも同じ**

実際に保存されている発話（会話 / 単語セッションの 15 発話）をそのキャラの現行スタイルで
合成して測ると、Chobi 2.68 w/s に対し **Naruko 2.84 w/s**（発話区間ベース）。
つまり「Chobi と比べて Naruko が遅い」という差は TTS の出力には無い。

**(3) 遅く感じる正体は「短い感嘆調の行が間延びすること」と「絶対的な話速の低さ」**

- 実発話で最も遅かったのは Naruko の `Yeah, like me and my ramen dishes, ha!` = **2.10 w/s**。
  笑いや間投詞の入った短い行はモデルが伸ばして読む。Naruko はこの型の行が多い
- 前後の無音が 1 発話あたり **前 0.28 秒 + 後 0.35 秒**ほど付く。1 ターンに 2〜3 発話あるので
  ターン全体では 1 秒前後の無音が乗る（両キャラ共通）
- 全体としても現行は 2.7〜2.9 w/s（発話区間ベース ≒ 165 wpm、無音込みだと約 140 wpm）で、
  英語の日常会話（150〜190 wpm）の下限寄り

**(4) 前置文に速さの指示を足すと実測で速くなる**

Naruko の前置文に `Speak at a brisk, natural conversational pace, without dragging out words:`
を足して、実セッションの Naruko 発話 5 件で比較（発話区間ベース）:

| 発話 | 現行 | 速さ指示あり |
| --- | --- | --- |
| Oh, I never get around to washing my dishes right away… | 3.12 | 3.88 (+24%) |
| Yeah, like me and my ramen dishes, ha! | 2.10 | 2.27 (+8%) |
| Ooh, what trip? I want to hear about it! | 3.41 | 3.75 (+10%) |
| Miso ramen sounds so good right now… | 2.81 | 3.09 (+10%) |
| Bye Akira, see you next time! | 2.93 | 3.45 (+18%) |
| **平均** | **2.87** | **3.29 (+14%)** |

**(5) voice を替えても速度はあまり動かない**（Naruko 用前置文・2 回平均）

Autonoe 3.54 / Callirrhoe 3.39 / Kore 3.29 / Puck 3.27 / **Aoede 3.24** / Laomedeia 2.94 / Zephyr 2.95。
Aoede は中位で、上位の Autonoe でも +9% 程度。**前置文の指示（+14%）のほうが効く。**

**(6) 犯人でないと分かったもの**

- 再生側（`StreamingAudioPlayer` は 24kHz 固定・キャラ分岐なし。レート取り違えなら Chobi も遅くなる）
- 文中の長い間（300ms 以上の無音は実測 0 秒）
- 声の高さ（中央値 F0 は Leda 180〜192Hz に対し Aoede 210〜227Hz で、Naruko のほうが高い）

## 対応方針（調査結果を見てから決める）

実測を踏まえた対応は **`ChatCharacter.speechStyle` の前置文を変える**（Chobi のみ）。
voice の差し替えは効きが小さいわりに声質が変わるので採らない。
再生側のレート変換（音程が変わる）も不要。

## 対応（2026-07-28 実施）

Chobi の前置文には速さの指示を足すだけでは効きが弱かった（実発話 10 件で 2.62 → 2.78、+6%）。
**"calm" が話速を引っ張っている**と見て語そのものを替えた案を測ったところ、こちらが効いた。

| 前置文 | w/s（実 Chobi 発話 10 件） |
| --- | --- |
| 現行 | 2.52 |
| calm を残して速さの指示だけ足す | 2.74 |
| calm を残して強い速さの指示 | 2.74 |
| **"calm" → "lively" + 速さの指示** | **2.85** |

採用した前置文（`ChatCharacter.chobi.speechStyle`）:

```
Read aloud in a warm, lively, gently cheerful voice, like a friendly teacher chatting with
a student. Speak at a brisk, natural conversational pace, without dragging out words:
```

ばらつきがあるので現行と採用案を各 2 回で取り直して確認: **2.57 → 2.87 w/s（+12%）**、
最も遅い行も 1.92 → 2.15。Naruko（2.84）と同程度になった。

- **Naruko は変更しない**（実測で遅くなく、今回の対象でもないため）
- キャラ設定の「落ち着いて温かい」は system prompt 側で保つ。ここで変えたのは
  **読み上げの声色の指示だけ**（`docs/specs/conversation-design.md` に決定として追記）
- voice の差し替え（Autonoe 等）は効きが小さいわりに声質が変わるので採らなかった
- 単体テストは前置文の文言に依存していない（`CloudPipelineProtocolTests` は
  `speechStyle.styleInstruction` を参照して前置を検証する形）ので、198 件そのままパス
- **実機での聞こえ方は未確認**。before / after の wav をセッションの作業ディレクトリに置いた
  （`chobi-before.wav` 2.34 w/s / `chobi-after.wav` 2.78 w/s。同じ説明文）

## 影響範囲

- `Conversation/ChatCharacter.swift`（voice / スタイル前置文）
- `docs/specs/conversation-design.md`（voice の確定値を書いてあるので更新する）

**変更しない**: TTS クライアント・チャンカー・再生経路（切り分けで犯人でないと分かればそのまま）。

## テスト方針

- 話速はサーバ側の生成結果なので単体テストでは押さえられない。
  `GeminiTTSClient.makeRequestBody` のテスト（前置文がテキスト先頭に付くこと）は既存のまま
- 実測スクリプトの結果をこのファイルに記録する
- 最終確認は実機（シミュレータでも音は出るが、実際の会話テンポは実機で聞く）
