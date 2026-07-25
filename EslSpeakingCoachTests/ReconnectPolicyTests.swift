import XCTest
@testable import EslSpeakingCoach

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffSequenceThenGivesUp() {
        var policy = ReconnectPolicy(maxAttempts: 3, delays: [0.5, 1.0, 2.0])
        XCTAssertEqual(policy.nextDelay(), 0.5)
        XCTAssertEqual(policy.attempt, 1)
        XCTAssertEqual(policy.nextDelay(), 1.0)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertNil(policy.nextDelay())
        XCTAssertNil(policy.nextDelay(), "上限到達後は何度呼んでも nil のまま")
    }

    func testDelaysShorterThanAttemptsRepeatLastValue() {
        var policy = ReconnectPolicy(maxAttempts: 4, delays: [0.5, 2.0])
        XCTAssertEqual(policy.nextDelay(), 0.5)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertEqual(policy.nextDelay(), 2.0)
        XCTAssertNil(policy.nextDelay())
    }

    func testResetRestartsSequence() {
        var policy = ReconnectPolicy(maxAttempts: 2, delays: [0.5, 1.0])
        XCTAssertEqual(policy.nextDelay(), 0.5)
        XCTAssertEqual(policy.nextDelay(), 1.0)
        XCTAssertNil(policy.nextDelay())

        policy.reset()
        XCTAssertEqual(policy.attempt, 0)
        XCTAssertEqual(policy.nextDelay(), 0.5, "接続確立後の切断はまた 1 回目から数える")
    }

    func testResetMidSequence() {
        var policy = ReconnectPolicy(maxAttempts: 3, delays: [0.5, 1.0, 2.0])
        XCTAssertEqual(policy.nextDelay(), 0.5)
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 0.5)
        XCTAssertEqual(policy.nextDelay(), 1.0)
    }
}
