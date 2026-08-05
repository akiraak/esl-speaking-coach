import SwiftData
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
        XCTAssertNil(store.latestUpdatedAt())
        XCTAssertTrue(store.currentNotes().isEmpty)
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

    // MARK: - scope（docs/plans/archive/per-character-memory.md）

    /// 3 本は互いに独立して保存・上書きされる。
    func testScopedNotesAreIndependent() throws {
        let store = try makeStore()
        store.save(text: "learner note", scope: .shared, sourceSessionID: nil)
        store.save(text: "chobi note", scope: .character(.chobi), sourceSessionID: nil)
        store.save(text: "naruko note", scope: .character(.naruko), sourceSessionID: nil)

        XCTAssertEqual(store.currentNote(.shared), "learner note")
        XCTAssertEqual(store.currentNote(.character(.chobi)), "chobi note")
        XCTAssertEqual(store.currentNote(.character(.naruko)), "naruko note")

        store.save(text: "chobi note 2", scope: .character(.chobi), sourceSessionID: nil)
        XCTAssertEqual(store.currentNote(.character(.chobi)), "chobi note 2")
        XCTAssertEqual(store.currentNote(.shared), "learner note")
        XCTAssertEqual(store.currentNote(.character(.naruko)), "naruko note")
    }

    func testCurrentNotesReadsAllThree() throws {
        let store = try makeStore()
        store.save(text: "learner note", scope: .shared, sourceSessionID: nil)
        store.save(text: "chobi note", scope: .character(.chobi), sourceSessionID: nil)

        let notes = store.currentNotes()
        XCTAssertEqual(notes.learner, "learner note")
        XCTAssertEqual(notes.chobi, "chobi note")
        XCTAssertNil(notes.naruko)
        XCTAssertFalse(notes.isEmpty)
    }

    /// キャラノートが nil のときは前回のノートを維持する（学習者ノートだけ更新される）。
    func testSaveAllKeepsPreviousCharacterNoteWhenNil() throws {
        let store = try makeStore()
        store.saveAll(
            learner: "learner 1", chobi: "chobi 1", naruko: "naruko 1", sourceSessionID: nil)
        store.saveAll(learner: "learner 2", chobi: nil, naruko: "naruko 2", sourceSessionID: nil)

        XCTAssertEqual(store.currentNote(.shared), "learner 2")
        XCTAssertEqual(store.currentNote(.character(.chobi)), "chobi 1")
        XCTAssertEqual(store.currentNote(.character(.naruko)), "naruko 2")
    }

    /// 個別リセットは他の scope を消さない。
    func testResetScopeKeepsOtherScopes() throws {
        let store = try makeStore()
        store.saveAll(
            learner: "learner note", chobi: "chobi note", naruko: "naruko note",
            sourceSessionID: nil)

        store.reset(.character(.chobi))
        XCTAssertNil(store.currentNote(.character(.chobi)))
        XCTAssertEqual(store.currentNote(.shared), "learner note")
        XCTAssertEqual(store.currentNote(.character(.naruko)), "naruko note")

        store.reset(.shared)
        XCTAssertNil(store.currentNote(.shared))
        XCTAssertEqual(store.currentNote(.character(.naruko)), "naruko note")
    }

    func testResetAllDeletesEveryScope() throws {
        let store = try makeStore()
        store.saveAll(
            learner: "learner note", chobi: "chobi note", naruko: "naruko note",
            sourceSessionID: nil)
        store.resetAll()

        XCTAssertTrue(store.currentNotes().isEmpty)
        XCTAssertNil(store.latestUpdatedAt())
    }

    /// 管理画面のサマリ用: 3 本のうち最新の更新時刻を返す。
    func testLatestUpdatedAtReturnsNewestAcrossScopes() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSinceNow: -600)
        let recent = Date(timeIntervalSinceNow: -60)
        store.save(text: "learner note", scope: .shared, sourceSessionID: nil, at: old)
        store.save(
            text: "chobi note", scope: .character(.chobi), sourceSessionID: nil, at: recent)

        XCTAssertEqual(store.latestUpdatedAt(), recent)
    }

    /// 記憶ノートが 1 本だった頃のレコード（scopeRawValue が nil）は学習者ノートとして読める。
    func testLegacyRecordWithoutScopeReadsAsShared() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(CharacterMemoryRecord(
            text: "legacy note", sourceSessionID: nil, scopeRawValue: nil))
        try context.save()

        let store = CharacterMemoryStore(container: container)
        XCTAssertEqual(store.currentNote(.shared), "legacy note")
        XCTAssertNil(store.currentNote(.character(.chobi)))

        // 以後の更新も同じレコードを上書きする（重複しない）
        store.save(text: "updated", scope: .shared, sourceSessionID: nil)
        XCTAssertEqual(store.currentNote(.shared), "updated")
        store.reset(.shared)
        XCTAssertNil(store.currentNote(.shared))
    }

    /// 未知の scope 値（将来のキャラ追加後にロールバックした等）は shared として読む。
    func testUnknownScopeValueFallsBackToShared() {
        XCTAssertEqual(MemoryScope(storedValue: nil), .shared)
        XCTAssertEqual(MemoryScope(storedValue: "someone"), .shared)
        XCTAssertEqual(MemoryScope(storedValue: "chobi"), .character(.chobi))
        XCTAssertEqual(MemoryScope.character(.naruko).storedValue, "naruko")
        XCTAssertNil(MemoryScope.shared.storedValue)
    }
}
