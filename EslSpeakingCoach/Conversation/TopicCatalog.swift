import Foundation

/// トピックのジャンル（何について話すか）。
/// `id` はプロンプトと履歴の両方で使う安定キーなので、一度出したら変えない。
struct TopicGenre: Sendable, Equatable, Identifiable {
    let id: String
    /// プロンプトへ載せる英語表現
    let english: String
    /// 仕様書・管理画面向けの日本語ラベル
    let japanese: String
}

/// トピックの「話し方」（どう話すか）。同じジャンルでも型が変われば使う文法と発話の質が変わる。
struct TopicStyle: Sendable, Equatable, Identifiable {
    let id: String
    /// プロンプトへ載せる英語表現（学習者が取る発話の型）
    let english: String
    let japanese: String
}

/// 3 件のあいだで散らす難易度。
enum TopicDifficulty: String, Sendable, CaseIterable {
    case easy
    case normal
    case challenging

    var english: String {
        switch self {
        case .easy: return "easy"
        case .normal: return "normal"
        case .challenging: return "slightly challenging"
        }
    }
}

/// 候補 1 件ぶんの割り当て（ジャンル × 話し方 × 難易度）。
struct TopicAssignment: Sendable, Equatable {
    let genre: TopicGenre
    let style: TopicStyle
    let difficulty: TopicDifficulty
}

/// トピックの多様性をアプリ側から注入するためのカタログ（topic-variety.md 方針 A）。
/// プロンプトにジャンルを例示列挙するとモデルがその中を回ってしまうため、
/// リクエストごとにここからサンプリングして「候補 N はこのジャンル・この型で」と指示する。
enum TopicCatalog {
    static let genres: [TopicGenre] = [
        TopicGenre(id: "food", english: "food and eating", japanese: "食べもの"),
        TopicGenre(id: "travel", english: "travel and trips", japanese: "旅"),
        TopicGenre(id: "work-study", english: "work and studying", japanese: "仕事・勉強"),
        TopicGenre(id: "hobbies", english: "hobbies and side projects", japanese: "趣味"),
        TopicGenre(id: "stories", english: "movies, music and books", japanese: "映画・音楽・本"),
        TopicGenre(id: "seasons", english: "seasons and weather", japanese: "季節と天気"),
        TopicGenre(id: "shopping", english: "shopping and belongings", japanese: "買いものと持ちもの"),
        TopicGenre(id: "neighborhood", english: "your town and neighborhood", japanese: "街と近所"),
        TopicGenre(id: "housework", english: "housework and daily chores", japanese: "家事と暮らし"),
        TopicGenre(id: "health", english: "health and exercise", japanese: "健康と運動"),
        TopicGenre(id: "money", english: "how you spend money", japanese: "お金の使い方"),
        TopicGenre(id: "technology", english: "technology, gadgets and apps", japanese: "テクノロジーとアプリ"),
        TopicGenre(id: "childhood", english: "childhood memories", japanese: "子どものころの思い出"),
        TopicGenre(id: "people", english: "family and friends", japanese: "家族と友だち"),
        TopicGenre(id: "animals", english: "pets and animals", japanese: "ペットと動物"),
        TopicGenre(id: "mishaps", english: "mishaps and embarrassing moments", japanese: "失敗談・ハプニング"),
        TopicGenre(id: "habits", english: "habits you changed or want to change", japanese: "習慣を変えた話"),
        TopicGenre(id: "dislikes", english: "things you are bad at or dislike", japanese: "苦手なもの"),
        TopicGenre(id: "aspirations", english: "things you admire or want to try", japanese: "憧れ・やってみたいこと"),
        TopicGenre(id: "small-pride", english: "something you are quietly proud of", japanese: "ちょっとした自慢"),
        TopicGenre(id: "what-if", english: "imaginary what-if situations", japanese: "もしもの想像"),
        TopicGenre(id: "news", english: "something you saw in the news", japanese: "ニュースで見かけた話"),
        TopicGenre(id: "sports", english: "sports", japanese: "スポーツ"),
        TopicGenre(id: "games", english: "games and playing", japanese: "ゲーム"),
        TopicGenre(id: "transport", english: "vehicles and getting around", japanese: "乗りものと移動"),
        TopicGenre(id: "sleep", english: "sleep, mornings and nights", japanese: "眠りと朝晩"),
        TopicGenre(id: "language", english: "learning languages and words", japanese: "ことばと語学"),
        TopicGenre(id: "celebrations", english: "holidays and celebrations", japanese: "行事とお祝い"),
    ]

    static let styles: [TopicStyle] = [
        TopicStyle(
            id: "recall", english: "recall a past experience and tell it as a story",
            japanese: "思い出を語る"),
        TopicStyle(
            id: "explain", english: "explain how something is done, step by step",
            japanese: "説明する"),
        TopicStyle(
            id: "compare", english: "compare two options and pick one", japanese: "比べて選ぶ"),
        TopicStyle(
            id: "opinion", english: "state an opinion and agree or disagree",
            japanese: "意見を言う"),
        TopicStyle(
            id: "imagine", english: "imagine a hypothetical situation", japanese: "想像する"),
        TopicStyle(
            id: "plan", english: "make a plan for something upcoming", japanese: "計画を立てる"),
        TopicStyle(
            id: "describe", english: "describe something in front of you in detail",
            japanese: "描写する"),
        TopicStyle(
            id: "recommend", english: "teach or recommend something to a friend",
            japanese: "教える・すすめる"),
    ]

    /// `id` からジャンルを引く（履歴に保存した id の復元用）。
    static func genre(id: String) -> TopicGenre? {
        genres.first { $0.id == id }
    }
}

/// カタログから候補ぶんの割り当てを引くサンプラー。
/// RNG は注入可能にしてテストで固定シードを使えるようにする。
enum TopicAssignmentSampler {
    /// `count` 件ぶんの割り当てを引く。3 件はすべて別ジャンル・別の話し方・別の難易度になる。
    /// `excludingGenreIDs` は直近セッションで使ったジャンル。除外しきって足りなくなる場合は
    /// 除外を捨てて全件から引く（候補ゼロを避ける）。
    static func sample<G: RandomNumberGenerator>(
        count: Int = 3, excludingGenreIDs: [String] = [], using rng: inout G
    ) -> [TopicAssignment] {
        guard count > 0 else { return [] }
        let excluded = Set(excludingGenreIDs)
        var pool = TopicCatalog.genres.filter { !excluded.contains($0.id) }
        if pool.count < count { pool = TopicCatalog.genres }
        let pickedGenres = pool.shuffled(using: &rng).prefix(count)
        let pickedStyles = TopicCatalog.styles.shuffled(using: &rng)
        // 難易度は 3 件で散らす。count が 3 を超えたら循環させる
        let difficulties = TopicDifficulty.allCases.shuffled(using: &rng)

        return pickedGenres.enumerated().map { index, genre in
            TopicAssignment(
                genre: genre,
                style: pickedStyles[index % pickedStyles.count],
                difficulty: difficulties[index % difficulties.count])
        }
    }
}
