# 会話生成モデル比較トランスクリプト（2026-07-25）

`model_compare_spike.py` による claude-opus-5 / claude-sonnet-5 / claude-haiku-4-5 の比較。
同一シナリオ 5 ターン（トピック開始 ×2、recast、短文回答、詰まり救済）をストリーミング実行。
生ログは `model_compare_result.txt`。

- **first** = 最初の文が確定するまでの秒数（= TTS を開始できるタイミング。体感レイテンシに直結）
- **total** = ターン全文の生成完了までの秒数

## サマリ

| モデル | first 平均 | total 平均 | 出力トークン平均 | 料金 (in/out per MTok) |
| --- | --- | --- | --- | --- |
| claude-opus-5（現行既定） | 2.69s ※ | 3.95s | 74 | $5 / $25 |
| claude-sonnet-5 | 1.55s | 2.58s | 74 | $3 / $15（2026-08 末まで $2 / $10） |
| claude-haiku-4-5 | 0.85s | 1.23s | 50 | $1 / $5 |

※ Opus の初回 5.93s はプロンプト更新直後のキャッシュ書き込みを含む外れ値。除くと 1.7〜2.3s。

## claude-opus-5

**Topic: Planning a trip — opening** [first=5.93s total=6.90s]

> **Chobi:** Let's talk about planning a trip. I'm always dreaming about a quiet trip with coffee and a book.
> **Naruko:** Ooh, I want to go somewhere with amazing ramen!
> **Chobi:** If you could plan any trip right now, where would you go?

**recast テスト** — 👤 *I want to go to Okinawa this summer. I go there last year with my family and it was very fun.* [first=1.73s total=2.76s]

> **Chobi:** Okinawa again, nice! So you went there last year with your family and had a great time. What did you enjoy the most on that trip?

**Topic: Food you can't quit — opening** [first=1.69s total=2.97s]

> **Chobi:** New topic! Some foods are just impossible to give up, no matter what.
> **Naruko:** For me it's ramen. I could eat it every single day!
> **Chobi:** What's one food you can't quit?

**短文回答** — 👤 *I like ramen.* [first=1.78s total=3.72s]

> **Naruko:** Yes! Ramen friends! High five!
> **Chobi:** Tell me about your favorite kind of ramen and where you eat it.

**詰まり救済** — 👤 *Hmm... I don't know.* [first=2.32s total=3.40s]

> **Chobi:** Naruko loves rich pork soup ramen, and I usually pick a light soy sauce one. Which soup do you like better, thick and rich or light and simple?

## claude-sonnet-5

**Topic: Planning a trip — opening** [first=1.33s total=2.31s]

> **Chobi:** Let's talk about trips! If you could plan a trip right now, where would you want to go?
> **Naruko:** Ooh I love this topic, I'm still dreaming of Okinawa lol. Where's your dream spot?

※ 「学習者向け質問は 1 つ」ルールを逸脱（両キャラが質問）。Naruko に "lol" が混入（TTS がそのまま読む）

**recast テスト** — 👤 *I want to go to Okinawa this summer. I go there last year with my family and it was very fun.* [first=1.57s total=2.14s]

> **Chobi:** Nice, so you went there last year and now you want to go again this summer, Okinawa really got you!
> **Naruko:** Okinawa again? What did you love most about it, the beach or the food?

**Topic: Food you can't quit — opening** [first=1.29s total=4.55s]

> **Chobi:** Ooh, food you can't quit, that's an easy one for me, coffee counts, right?
> **Naruko:** For me it's totally ramen, I could eat it every single day!
> **Chobi:** So tell us, what food can you just never quit?

**短文回答** — 👤 *I like ramen.* [first=1.85s total=1.87s]

> **Naruko:** Yay, ramen buddy! What kind do you usually get, like miso or shoyu or tonkotsu?

**詰まり救済** — 👤 *Hmm... I don't know.* [first=1.72s total=2.05s]

> **Chobi:** No worries, let's make it simple. Do you like your ramen soup thick and rich, or light and clear?

## claude-haiku-4-5

**Topic: Planning a trip — opening** [first=1.00s total=1.33s]

> **Chobi:** Oh, are you thinking about going somewhere fun soon?
> **Naruko:** Yeah, tell us! Where would you like to go?
> **Chobi:** What kind of place interests you most—a beach, mountains, a city, or something else?

※ ペルソナ表出なし（コーヒー・ラーメン等が出ない）

**recast テスト** — 👤 *I want to go to Okinawa this summer. I go there last year with my family and it was very fun.* [first=0.98s total=1.41s]

> **Chobi:** Okinawa again—sounds like you really loved it! You went there last year with your family, that's nice. What did you enjoy most about it?

**Topic: Food you can't quit — opening** [first=0.68s total=1.33s]

> **Chobi:** Oh, I love this topic! I'm curious what everyone's guilty pleasure food is.
> **Naruko:** Yes! Like food you eat even when you know you shouldn't, right?
> **Chobi:** Exactly. So what's a food you can't quit, even though maybe you want to sometimes?

※ Naruko がラーメン好きに言及せず。キャラ同士の内輪会話ぎみ

**短文回答** — 👤 *I like ramen.* [first=0.82s total=1.05s]

> **Naruko:** Oh, ramen! Me too, I love ramen so much!
> **Chobi:** How often do you eat ramen, and what's your favorite kind?

**詰まり救済** — 👤 *Hmm... I don't know.* [first=0.77s total=1.05s]

> **Chobi:** That's okay! Let me ask differently—do you prefer ramen with a rich, heavy broth, or a lighter one?

## 所見

- **Opus 5**: ルール違反なし・ペルソナ最濃・詰まり救済最良（自分たちの例示 → 二択）。最も遅い
- **Sonnet 5**: 品質ほぼ Opus 並み。"lol" 混入と質問 2 つの逸脱が各 1 回（プロンプト調整で対処できる見込み）
- **Haiku 4.5**: 圧倒的に速く安いが、ペルソナがほぼ消え「相手感」が薄い。ルール・recast・救済自体は機能

## 決定と最終検証（claude-sonnet-5 採用）

ユーザー決定により **claude-sonnet-5** を会話生成モデルに採用。逸脱対策として system prompt に
①チャットスラング禁止 ②「最終行 = 学習者への唯一の質問」③開始ターンの構成手順、を追加して再検証した（生ログ `sonnet5_verify_result.txt`）。**5/5 ターン合格**（first 平均 1.73s / total 平均 2.34s）:

**Topic: Planning a trip — opening** [first=2.55s total=3.19s]

> **Chobi:** I have been wanting to plan a mystery-novel tour, visiting places from my favorite books.
> **Naruko:** I just want a trip with good ramen and karaoke, honestly.
> **Chobi:** If you could plan a trip anywhere right now, where would you go?

**recast テスト** [first=1.49s total=1.90s]

> **Chobi:** Nice, so you went there last year with your family and had a great time. What made it so fun?

**Topic: Food you can't quit — opening** [first=1.25s total=2.14s]

> **Chobi:** For me it's coffee, I really can't quit my morning cup.
> **Naruko:** Mine is ramen, I could eat it every single day, no joke.
> **Chobi:** What food can you just never quit?

**短文回答** — 👤 *I like ramen.* [first=1.83s total=1.85s]

> **Chobi:** Nice, a fellow ramen lover! What kind do you usually get, like miso or shoyu?

**詰まり救済** — 👤 *Hmm... I don't know.* [first=1.55s total=2.60s]

> **Chobi:** No worries, let's think about it together. Naruko, what does your favorite ramen shop serve?
> **Naruko:** Mine is a spicy miso ramen place near my house, so good. What about you, do you like your ramen spicy or mild?

詰まり救済では Chobi が Naruko に質問を振って回答の手本を見せてから学習者に戻す、想定以上の好挙動を確認。

トピック生成も claude-sonnet-5 で確認済み（`topic_sonnet_check.py`、structured outputs 準拠、3.57s）:

> A movie that surprised you / Weekend hobby you love / A funny work story

フィードバック生成（会話後・高品質優先）は claude-opus-5 のまま。CLAUDE.md の規約も更新済み。
