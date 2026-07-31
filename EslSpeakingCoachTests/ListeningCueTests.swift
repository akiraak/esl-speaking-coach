import XCTest
@testable import EslSpeakingCoach

final class ListeningCueTests: XCTestCase {
    private let kinds: [ListeningCue.Kind] = [.start, .end]

    func testSamplesAreNonEmptyAndWithinAmplitudeBounds() {
        for kind in kinds {
            let samples = ListeningCue.makeSamples(kind: kind, sampleRate: 24000)
            XCTAssertFalse(samples.isEmpty)
            XCTAssertTrue(samples.allSatisfy { abs($0) <= 1.0 })
            // 無音でないこと（包絡・振幅の掛け違いで全ゼロにならない）
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
        }
    }

    func testStartsAndEndsNearZeroToAvoidClicks() {
        for kind in kinds {
            let samples = ListeningCue.makeSamples(kind: kind, sampleRate: 24000)
            XCTAssertLessThan(abs(samples.first ?? 1), 0.01)
            XCTAssertLessThan(abs(samples.last ?? 1), 0.01)
        }
    }

    func testDurationIsShort() {
        let sampleRate = 24000.0
        for kind in kinds {
            let samples = ListeningCue.makeSamples(kind: kind, sampleRate: sampleRate)
            let seconds = Double(samples.count) / sampleRate
            // 会話のテンポを崩さない長さ（0.5 秒未満）
            XCTAssertLessThan(seconds, 0.5)
        }
    }

    /// 開始（上昇）と終了（下降）は耳で聞き分けられる別の波形であること
    func testStartAndEndCuesDiffer() {
        XCTAssertNotEqual(
            ListeningCue.makeSamples(kind: .start, sampleRate: 24000),
            ListeningCue.makeSamples(kind: .end, sampleRate: 24000))
    }

    /// kind 省略は従来の開始ジングル（既存呼び出しの互換）
    func testDefaultKindIsStart() {
        XCTAssertEqual(
            ListeningCue.makeSamples(sampleRate: 24000),
            ListeningCue.makeSamples(kind: .start, sampleRate: 24000))
    }
}
