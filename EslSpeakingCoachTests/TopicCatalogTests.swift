import XCTest
@testable import EslSpeakingCoach

/// 固定シードの決定的 RNG（SplitMix64）。サンプリング結果を再現するためテスト側に置く。
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TopicCatalogTests: XCTestCase {
    @MainActor
    func testCatalogIDsAreUnique() {
        XCTAssertEqual(Set(TopicCatalog.genres.map(\.id)).count, TopicCatalog.genres.count)
        XCTAssertEqual(Set(TopicCatalog.styles.map(\.id)).count, TopicCatalog.styles.count)
        // 直近ジャンルを除外しても 3 件引ける余裕があること
        XCTAssertGreaterThanOrEqual(
            TopicCatalog.genres.count, ChatRoomStore.recentGenreLimit + 3)
        XCTAssertGreaterThanOrEqual(TopicCatalog.styles.count, 3)
    }

    /// 1 カードの中の多様性: 3 件はすべて別ジャンル・別の話し方・別の難易度になる。
    func testSampleGivesDistinctGenresStylesAndDifficulties() {
        for seed in UInt64(1)...50 {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let assignments = TopicAssignmentSampler.sample(using: &rng)
            XCTAssertEqual(assignments.count, 3)
            XCTAssertEqual(Set(assignments.map(\.genre.id)).count, 3, "seed \(seed)")
            XCTAssertEqual(Set(assignments.map(\.style.id)).count, 3, "seed \(seed)")
            XCTAssertEqual(Set(assignments.map(\.difficulty)).count, 3, "seed \(seed)")
        }
    }

    /// 同じ RNG 状態なら再現し、シードが違えば散る（リクエストごとの揺らぎの担保）。
    func testSampleIsDeterministicPerSeedAndVariesAcrossSeeds() {
        var first = SeededRandomNumberGenerator(seed: 42)
        var second = SeededRandomNumberGenerator(seed: 42)
        XCTAssertEqual(
            TopicAssignmentSampler.sample(using: &first),
            TopicAssignmentSampler.sample(using: &second))

        var genreSets: Set<String> = []
        for seed in UInt64(1)...20 {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let ids = TopicAssignmentSampler.sample(using: &rng).map(\.genre.id).sorted()
            genreSets.insert(ids.joined(separator: ","))
        }
        XCTAssertGreaterThan(genreSets.count, 10)
    }

    func testSampleExcludesRecentGenres() {
        let excluded = Array(TopicCatalog.genres.prefix(8).map(\.id))
        for seed in UInt64(1)...50 {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let assignments = TopicAssignmentSampler.sample(
                excludingGenreIDs: excluded, using: &rng)
            XCTAssertEqual(assignments.count, 3)
            for assignment in assignments {
                XCTAssertFalse(excluded.contains(assignment.genre.id), "seed \(seed)")
            }
        }
    }

    /// 除外しきってプールが足りなくなったらリセットして必ず 3 件返す（候補ゼロを避ける）。
    func testSampleFallsBackWhenExclusionEmptiesPool() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        let assignments = TopicAssignmentSampler.sample(
            excludingGenreIDs: TopicCatalog.genres.map(\.id), using: &rng)
        XCTAssertEqual(assignments.count, 3)
        XCTAssertEqual(Set(assignments.map(\.genre.id)).count, 3)
    }

    func testGenreLookupByID() {
        XCTAssertEqual(TopicCatalog.genre(id: "food")?.japanese, "食べもの")
        XCTAssertNil(TopicCatalog.genre(id: "no-such-genre"))
    }
}
