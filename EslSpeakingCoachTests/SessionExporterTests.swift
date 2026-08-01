import XCTest
@testable import EslSpeakingCoach

@MainActor
final class SessionExporterTests: XCTestCase {
    func testBuildExportContainsSessionsOldestFirst() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let historyStore = ChatHistoryStore(container: container)
        let memoryStore = CharacterMemoryStore(container: container)

        let firstID = UUID()
        historyStore.beginSession(id: firstID, topicTitle: "Morning routines")
        historyStore.appendMessage(id: UUID(), speaker: .user, text: "I wake up at six.")
        historyStore.appendMessage(id: UUID(), speaker: .chobi, text: "That is early.")
        historyStore.appendLog(kind: .metrics, text: "TTFT 850ms")
        historyStore.endActiveSession()
        historyStore.saveFeedback(
            sessionID: firstID,
            feedback: SessionFeedback(
                summary: "よく話せました。",
                corrections: [
                    .init(original: "I wake at six", improved: "I wake up at six", note: "句動詞")
                ],
                tryPhrases: [.init(phrase: "rise and shine", meaning: "起きて")]))

        let secondID = UUID()
        historyStore.beginSession(id: secondID, topicTitle: "apple", kind: .word)
        historyStore.appendMessage(id: UUID(), speaker: .naruko, text: "Apple is my favorite word!")
        historyStore.endActiveSession()

        memoryStore.save(text: "Learner likes ramen.", sourceSessionID: firstID)

        let export = SessionExporter.buildExport(
            historyStore: historyStore, memoryStore: memoryStore)

        XCTAssertEqual(export.memoryNote, "Learner likes ramen.")
        XCTAssertEqual(export.sessions.map(\.id), [firstID, secondID])
        XCTAssertEqual(export.sessions.map(\.kind), ["conversation", "word"])

        let first = export.sessions[0]
        XCTAssertEqual(first.messages.map(\.speaker), ["user", "chobi"])
        XCTAssertEqual(first.logs.map(\.text), ["TTFT 850ms"])
        XCTAssertEqual(first.feedback?.corrections.first?.improved, "I wake up at six")
        XCTAssertNotNil(first.endedAt)
        XCTAssertNil(export.sessions[1].feedback)
    }

    func testWriteJSONProducesDecodableFile() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let historyStore = ChatHistoryStore(container: container)
        let memoryStore = CharacterMemoryStore(container: container)

        let sessionID = UUID()
        historyStore.beginSession(id: sessionID, topicTitle: "Kyoto trip")
        historyStore.appendMessage(id: UUID(), speaker: .user, text: "I went to Kyoto.")
        historyStore.endActiveSession()

        let url = try SessionExporter.writeJSON(
            historyStore: historyStore, memoryStore: memoryStore)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExporter.Export.self, from: data)
        XCTAssertEqual(decoded.sessions.map(\.id), [sessionID])
        XCTAssertEqual(decoded.sessions[0].messages.first?.text, "I went to Kyoto.")
        XCTAssertNil(decoded.memoryNote)
    }
}
