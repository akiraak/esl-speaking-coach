import Foundation
import SwiftData

/// アプリ全体で共有する SwiftData コンテナ（端末内のみ。サーバー・iCloud 同期なし）。
enum AppModelContainer {
    static let shared: ModelContainer = {
        do {
            return try make(inMemory: false)
        } catch {
            // ストアが開けない場合はメモリ内で続行する（保存されないが会話機能は使える）。
            // in-memory の生成は失敗しない
            return try! make(inMemory: true)
        }
    }()

    /// テストは inMemory: true で独立したコンテナを作る。
    static func make(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([
            ChatSessionRecord.self,
            ChatMessageRecord.self,
            ChatSessionLogRecord.self,
            APIUsageRecord.self,
            CharacterMemoryRecord.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
