import XCTest
@testable import EslSpeakingCoach

@MainActor
final class CharacterMemoryStoreTests: XCTestCase {
    private func makeStore() throws -> CharacterMemoryStore {
        CharacterMemoryStore(container: try AppModelContainer.make(inMemory: true))
    }

    func testEmptyStoreReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(store.currentNote())
        XCTAssertNil(store.snapshot())
    }

    func testSaveAndLoad() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.save(text: "About the learner\n- Name is Akira.", sourceSessionID: sessionID)

        XCTAssertEqual(store.currentNote(), "About the learner\n- Name is Akira.")
        let snapshot = try XCTUnwrap(store.snapshot())
        XCTAssertEqual(snapshot.text, "About the learner\n- Name is Akira.")
        XCTAssertEqual(snapshot.sourceSessionID, sessionID)
    }

    /// ローリング更新: 常に単一レコードを上書きする。
    func testSaveOverwritesExistingNote() throws {
        let store = try makeStore()
        let firstAt = Date(timeIntervalSinceNow: -60)
        store.save(text: "old note", sourceSessionID: UUID(), at: firstAt)
        let secondSessionID = UUID()
        store.save(text: "new note", sourceSessionID: secondSessionID)

        XCTAssertEqual(store.currentNote(), "new note")
        let snapshot = try XCTUnwrap(store.snapshot())
        XCTAssertEqual(snapshot.sourceSessionID, secondSessionID)
        XCTAssertGreaterThan(snapshot.updatedAt, firstAt)
    }

    func testResetDeletesNote() throws {
        let store = try makeStore()
        store.save(text: "note", sourceSessionID: nil)
        store.reset()
        XCTAssertNil(store.currentNote())
        XCTAssertNil(store.snapshot())
    }
}
