"""実機データを使わずにモデル比較を回すための合成セッションを組み立てる。

出力は SessionExporter.Export と同じ形（fixtures/export.json 互換）なので、
既存の build_fixtures.mjs をそのまま通せる。

**これは実会話ではない。** 実機の書き出しが無くても比較を回せるようにするためのもので、
評価ケースが狙う状況（STT ノイズ・一語返答・日英混在・明示的な別れ・曖昧な終わり）を
意図的に仕込んである。学習者の英語には日本人学習者に典型的な誤り（冠詞落ち・時制の揺れ・
前置詞・和製英語）を混ぜてある。AI ターンは CoachSystemPrompt の台本規約に沿って手で書いた
中立な内容で、特定のモデルの癖に寄せていない（どのモデルにも等しく不利/有利にならないため）。
"""
import json, pathlib
from datetime import datetime, timedelta

BASE = datetime(2026, 7, 20, 21, 0, 0)


def session(sid, title, kind, messages, start_offset_days=0):
    start = BASE + timedelta(days=start_offset_days)
    out = []
    for i, (speaker, text) in enumerate(messages):
        out.append({
            "speaker": speaker,
            "text": text,
            "translation": None,
            "createdAt": (start + timedelta(seconds=25 * (i + 1))).isoformat() + "Z",
        })
    return {
        "id": sid,
        "topicTitle": title,
        "kind": kind,
        "startedAt": start.isoformat() + "Z",
        "endedAt": (start + timedelta(seconds=25 * (len(messages) + 1))).isoformat() + "Z",
        "messages": out,
        "logs": [],
        "feedback": None,
    }


# --- 1) 週末の失敗談: 序盤〜中盤の通常ターン、一語返答 -------------------------------
weekend = [
    ("chobi", "I tried to make bread last weekend and it came out flat like a pancake."),
    ("naruko", "Flat bread! That is still bread, kind of."),
    ("chobi", "What about you, did anything go wrong for you recently?"),
    ("user", "Yes. I try to cook curry but I forget the rice."),
    ("naruko", "Curry with no rice is a soup, right?"),
    ("chobi", "So what did you eat it with in the end?"),
    ("user", "Bread."),
    ("chobi", "Bread and curry, that is actually a real combination in some places."),
    ("naruko", "Tell me more about how the curry tasted."),
    ("user", "It was too spicy because I put many chili. My mouth was on fire and I drink milk."),
    ("naruko", "Milk is the correct emergency button, I use it too."),
    ("chobi", "How spicy do you usually like your food?"),
    ("user", "Not so spicy. I am weak person for spicy food."),
    ("naruko", "Same here, I am a level one player."),
    ("chobi", "What is one dish you can cook without any trouble?"),
    ("user", "Maybe omelette. I make it every morning for my son, he is five years old."),
]

# --- 2) 朝型か夜型か: STT ノイズ、日英混在、曖昧な終わり ----------------------------
morning = [
    ("naruko", "I am definitely a night person, my brain wakes up at eleven pm."),
    ("chobi", "Are you a morning person or a night person?"),
    ("user", "I am morning person. I wake up at five thirty every day."),
    ("chobi", "Five thirty is early. What do you do in that quiet time?"),
    ("user", "I read book and drink coffee. Sometime I study English too."),
    ("naruko", "Studying before the world wakes up, that is a power move."),
    ("chobi", "How long have you kept this routine?"),
    ("user", "About two years. Before that I was night person but I change after my son born."),
    ("naruko", "Kids rewrite the whole schedule, I hear."),
    ("chobi", "What was the hardest part about changing?"),
    ("user", "Hello."),  # STT が中盤に拾った無関係な発話（実機でよく起きるノイズ）
    ("chobi", "The first weeks are usually the hardest, so what helped you get through them?"),
    ("user", "I go to bed early, before ten. But weekend is difficult, I want to watch movie."),
    ("naruko", "Weekends are where good habits go to nap."),
    ("chobi", "What kind of movies do you stay up for?"),
    ("user", "えっと、SF movie. Star Wars とか、そういうの。I like space story."),
    ("naruko", "Space stories are worth losing sleep over, I will allow it."),
    ("chobi", "Which one would you recommend to someone who has never watched them?"),
    ("user", "Maybe Interstellar. It is little difficult but very beautiful."),
    ("naruko", "Adding it to my list right now."),
    ("chobi", "What made it beautiful for you?"),
    ("user", "Hmm, it is getting late. Maybe I should think about dinner soon."),
]

# --- 3) もし引っ越すなら: 長い履歴、学習者からの質問返し、明示的な別れ --------------
moving = [
    ("chobi", "If I could move anywhere, I would pick a small town near the sea."),
    ("naruko", "I would pick somewhere with a big bookstore."),
    ("chobi", "If you could move anywhere, where would you go?"),
    ("user", "I want to live in Fukuoka. I go there last year and the food was amazing."),
    ("naruko", "Fukuoka ramen is dangerous, you cannot stop at one bowl."),
    ("chobi", "What did you eat there that you still think about?"),
    ("user", "Motsunabe. It is hot pot with beef. Very rich taste."),
    ("chobi", "Rich and warm, that sounds like a winter dish."),
    ("naruko", "Would you move for the food alone?"),
    ("user", "Ha ha, maybe fifty percent food. Also the city is not too big, and rent is cheap than Tokyo."),
    ("chobi", "What would you miss most about where you live now?"),
    ("user", "My friends. And my mansion is very convenient, near the station."),
    ("naruko", "A mansion near the station, you are living the dream."),
    ("chobi", "How far is the station from your place?"),
    ("user", "Five minutes walking. Very good for rainy day."),
    ("chobi", "That is close. What would make you finally decide to move?"),
    ("user", "Maybe if my company allow remote work forever. By the way, how do you say 引っ越し in English?"),
    ("chobi", "We say \"moving\" or \"moving house\", for example \"I am moving next month\". So would remote work be enough to push you?"),
    ("user", "I think yes. But my wife want to stay near her parents, so it is difficult."),
    ("naruko", "Family gravity is strong."),
    ("chobi", "Have you two talked about a compromise?"),
    ("user", "Not seriously yet. Someday we discuss it."),
    ("naruko", "Someday is a very safe word."),
    ("chobi", "What would you want the conversation to start with?"),
    ("user", "This was fun. I have to go now. Goodbye, see you!"),
]

# --- 4) 単語練習「put off」: 単語モードの形式チェック用 ------------------------------
word_putoff = [
    ("chobi", "Today's word is \"put off\". It means to delay something to a later time."),
    ("naruko", "Oh, I put off my homework every single week."),
    ("chobi", "Can you try making a sentence with it?"),
    ("user", "I put off my dentist appointment."),
    ("naruko", "Brave. The dentist always wins in the end."),
    ("chobi", "Nice. Why did you put it off?"),
    ("user", "Because I am scared. Also I was busy in work last month."),
    ("chobi", "That is a natural use. Can you use it about something at work?"),
    ("user", "I put off the meeting to next week because my boss was sick."),
    ("naruko", "Sick boss, free week, not bad."),
    ("chobi", "Good. Now try it in past tense with a longer sentence."),
    ("user", "Last year I put off my English study for many months, and I regret it."),
    ("chobi", "That is a strong sentence. What made you start again?"),
    ("user", "My company decide to use English in meeting. So I have no choice."),
    ("naruko", "Nothing motivates like having no escape."),
    ("chobi", "How do you feel about those meetings now?"),
    ("user", "Still nervous but better. I can understand almost, but speaking is difficult."),
    ("chobi", "Can you make one more sentence with \"put off\", about the future this time?"),
    ("user", "I will not put off my presentation preparation this time."),
    ("naruko", "Write that down and put it on the wall."),
]

SESSIONS = [
    session("11111111-1111-4111-8111-111111111111", "週末の失敗談", "conversation", weekend, 0),
    session("22222222-2222-4222-8222-222222222222", "朝型か夜型か", "conversation", morning, 1),
    session("33333333-3333-4333-8333-333333333333", "もし引っ越すなら", "conversation", moving, 2),
    session("44444444-4444-4444-8444-444444444444", "put off", "word", word_putoff, 3),
]

MEMORY_NOTE = (
    "Learner lives near Tokyo and works in IT. Has a five-year-old son. "
    "Wakes up at 5:30 and studies English before work. Likes ramen, sci-fi movies and Fukuoka. "
    "Needs English for company meetings; understands more than he can say."
)

export = {
    "exportedAt": (BASE + timedelta(days=4)).isoformat() + "Z",
    "memoryNote": MEMORY_NOTE,
    "sessions": SESSIONS,
}

out = pathlib.Path(__file__).parent / "export.json"
out.write_text(json.dumps(export, ensure_ascii=False, indent=2), encoding="utf-8")
counts = {s["topicTitle"]: len(s["messages"]) for s in SESSIONS}
learner = {
    s["topicTitle"]: sum(1 for m in s["messages"] if m["speaker"] == "user") for s in SESSIONS
}
print("wrote", out)
print("messages:", counts)
print("learner turns:", learner)
