import XCTest
@testable import EslSpeakingCoach

final class ListeningCueTests: XCTestCase {
    func testSamplesAreNonEmptyAndWithinAmplitudeBounds() {
        let samples = ListeningCue.makeSamples(sampleRate: 24000)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 1.0 })
        // 無音でないこと（包絡・振幅の掛け違いで全ゼロにならない）
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    func testStartsAndEndsNearZeroToAvoidClicks() {
        let samples = ListeningCue.makeSamples(sampleRate: 24000)
        XCTAssertLessThan(abs(samples.first ?? 1), 0.01)
        XCTAssertLessThan(abs(samples.last ?? 1), 0.01)
    }

    func testDurationIsShort() {
        let sampleRate = 24000.0
        let samples = ListeningCue.makeSamples(sampleRate: sampleRate)
        let seconds = Double(samples.count) / sampleRate
        // 会話のテンポを崩さない長さ（0.5 秒未満）
        XCTAssertLessThan(seconds, 0.5)
    }
}
