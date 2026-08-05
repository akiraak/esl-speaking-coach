import Foundation
import OSLog
import SwiftData

/// 記憶ノートの用途（docs/plans/archive/per-character-memory.md）。
/// 学習者ノートは 2 キャラで共有し、キャラ自身のことだけを 1 本ずつ分ける。
/// キャラ 2 値は `ChatCharacter` から導出して定義を二重に持たない。
enum MemoryScope: Hashable, Sendable, Identifiable, CaseIterable {
    /// 学習者の事実 + 直近セッション要約（既存レコードがそのままこれ）
    case shared
    /// そのキャラ自身の身の上・出来事
    case character(ChatCharacter)

    static var allCases: [MemoryScope] {
        [.shared] + ChatCharacter.allCases.map(MemoryScope.character)
    }

    var id: String { storedValue ?? "shared" }

    /// SwiftData に保存する値。**shared は nil** ―― 記憶ノートが 1 本だった頃の
    /// 既存レコードが、そのまま学習者ノートとして読める（ライトウェイトマイグレーション）。
    var storedValue: String? {
        switch self {
        case .shared: return nil
        case .character(let character): return character.rawValue
        }
    }

    /// 永続化した値の復元（nil・未知はすべて shared）。
    init(storedValue: String?) {
        guard let storedValue, let character = ChatCharacter(rawValue: storedValue) else {
            self = .shared
            return
        }
        self = .character(character)
    }

    /// 管理画面の Picker とセクション見出しの表示名。
    var displayName: String {
        switch self {
        case .shared: return "学習者"
        case .character(let character): return character.displayName
        }
    }

    /// 生成プロンプト（`MemoryUpdateClient.systemPrompt`）がモデルへ指示している語数上限。
    /// **コード側では切り詰めていない**（指示が守られる保証はないので、管理画面で実際の長さを
    /// 見るための目安として使う）。プロンプトを変えたらここも合わせる。
    var wordLimit: Int {
        switch self {
        case .shared: return 400
        case .character: return 120
        }
    }

    /// 開始メッセージに積むときの制御メッセージのキー
    /// （`[Memory: ...]` / `[Memory about Chobi: ...]`）。
    var openingControlKey: String {
        switch self {
        case .shared: return "Memory"
        case .character(let character): return "Memory about " + character.displayName
        }
    }
}

/// キャラのセッション横断記憶（ローリング記憶ノート）。scope ごとに単一レコードを上書きする。
/// docs/plans/archive/character-memory.md の「記憶ノートの設計」と
/// docs/plans/archive/per-character-memory.md（scope 分割）に対応する。
@Model
final class CharacterMemoryRecord {
    /// 英語の箇条書きノート 1 本（MemoryUpdateClient が生成）
    var text: String
    var updatedAt: Date
    /// このノートを生成したセッション（デバッグ用の由来情報）
    var sourceSessionID: UUID?
    /// `MemoryScope.storedValue`（nil = shared = 学習者ノート）。
    /// optional 追加のみなので既存ストアはライトウェイトマイグレーションで開ける
    var scopeRawValue: String?

    init(
        text: String, updatedAt: Date = Date(), sourceSessionID: UUID?,
        scopeRawValue: String? = nil
    ) {
        self.text = text
        self.updatedAt = updatedAt
        self.sourceSessionID = sourceSessionID
        self.scopeRawValue = scopeRawValue
    }
}

/// 記憶ノートの読み書きストア。ChatRoomStore（セッション開始時の読み込み・終了時の上書き）と
/// 管理画面（閲覧・リセット）から使う。保存は best effort: 失敗しても会話は継続する。
@MainActor
final class CharacterMemoryStore {
    /// 管理画面用の値型スナップショット（@Model を View 側へ持ち出さない）。
    struct MemorySnapshot: Sendable {
        let text: String
        let updatedAt: Date
        let sourceSessionID: UUID?
    }

    private static let logger = Logger(
        subsystem: "com.akiraak.EslSpeakingCoach", category: "CharacterMemoryStore")

    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// 現在の記憶ノート本文（未生成なら nil）。セッション開始時の注入用。
    func currentNote(_ scope: MemoryScope = .shared) -> String? {
        fetchRecord(scope)?.text
    }

    /// セッション開始時に注入する 3 本をまとめて読む。
    func currentNotes() -> MemoryNotes {
        MemoryNotes(
            learner: currentNote(.shared),
            chobi: currentNote(.character(.chobi)),
            naruko: currentNote(.character(.naruko)))
    }

    /// 管理画面用: 記憶の全情報（未生成なら nil）。
    func snapshot(_ scope: MemoryScope = .shared) -> MemorySnapshot? {
        guard let record = fetchRecord(scope) else { return nil }
        return MemorySnapshot(
            text: record.text,
            updatedAt: record.updatedAt,
            sourceSessionID: record.sourceSessionID)
    }

    /// 管理画面のサマリ用: どれか 1 本でも更新されていればその最新時刻。
    func latestUpdatedAt() -> Date? {
        fetchRecords().map(\.updatedAt).max()
    }

    /// 更新済みノートで該当 scope の単一レコードを上書きする（無ければ作成）。
    func save(
        text: String, scope: MemoryScope = .shared, sourceSessionID: UUID?,
        at updatedAt: Date = Date()
    ) {
        write(text: text, scope: scope, sourceSessionID: sourceSessionID, at: updatedAt)
        save()
    }

    /// セッション終了時の 3 本同時更新（1 度の保存で書く。部分保存で組み合わせがずれない）。
    /// キャラノートが nil（今回そのキャラが自分の話をしなかった）なら**前回のノートを維持**する。
    func saveAll(
        learner: String, chobi: String?, naruko: String?, sourceSessionID: UUID?,
        at updatedAt: Date = Date()
    ) {
        write(text: learner, scope: .shared, sourceSessionID: sourceSessionID, at: updatedAt)
        if let chobi {
            write(
                text: chobi, scope: .character(.chobi),
                sourceSessionID: sourceSessionID, at: updatedAt)
        }
        if let naruko {
            write(
                text: naruko, scope: .character(.naruko),
                sourceSessionID: sourceSessionID, at: updatedAt)
        }
        save()
    }

    /// 管理画面用: 1 本だけ消す（他の scope は残る）。
    func reset(_ scope: MemoryScope = .shared) {
        // 想定は scope ごとに単一レコードだが、万一複数残っていても全部消す
        for record in fetchRecords(scope) {
            context.delete(record)
        }
        save()
    }

    /// 管理画面用: 3 本すべて消してキャラを白紙に戻す。
    func resetAll() {
        for record in fetchRecords() {
            context.delete(record)
        }
        save()
    }

    // MARK: - private

    private func write(text: String, scope: MemoryScope, sourceSessionID: UUID?, at updatedAt: Date) {
        if let record = fetchRecord(scope) {
            record.text = text
            record.updatedAt = updatedAt
            record.sourceSessionID = sourceSessionID
        } else {
            context.insert(CharacterMemoryRecord(
                text: text, updatedAt: updatedAt, sourceSessionID: sourceSessionID,
                scopeRawValue: scope.storedValue))
        }
    }

    private func fetchRecord(_ scope: MemoryScope) -> CharacterMemoryRecord? {
        fetchRecords(scope).first
    }

    /// scope の絞り込みは取得後にメモリ上で行う（レコードは高々 3 件。
    /// optional 比較の #Predicate は SwiftData 側の落とし穴が多く、利点が無い）。
    private func fetchRecords(_ scope: MemoryScope) -> [CharacterMemoryRecord] {
        fetchRecords().filter { MemoryScope(storedValue: $0.scopeRawValue) == scope }
    }

    private func fetchRecords() -> [CharacterMemoryRecord] {
        let descriptor = FetchDescriptor<CharacterMemoryRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("記憶ノートの保存に失敗: \(error.localizedDescription)")
        }
    }
}
