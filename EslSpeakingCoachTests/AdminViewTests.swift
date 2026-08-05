import XCTest
@testable import EslSpeakingCoach

/// 管理画面ルートの構成（docs/plans/archive/model-selection-in-admin.md Phase 1）。
@MainActor
final class AdminViewTests: XCTestCase {
    /// セクションへの入れ忘れ・重複はルートから辿れない項目 / 二重表示になるので落とす。
    func testSectionsCoverEveryTabExactlyOnce() {
        let listed = AdminView.sections.flatMap(\.tabs)
        XCTAssertEqual(Set(listed), Set(AdminView.Tab.allCases), "セクションに入っていない項目がある")
        XCTAssertEqual(listed.count, AdminView.Tab.allCases.count, "同じ項目が複数のセクションにある")
    }

    /// 表示名は `-open-admin <表示名>` の指定キーそのもの。変えると既存の起動引数が黙って効かなくなる。
    func testTabRawValuesAreStableLaunchArgumentKeys() {
        XCTAssertEqual(
            AdminView.Tab.allCases.map(\.rawValue),
            ["会話", "記憶", "料金", "診断", "容量", "モデル", "音声入力"])
    }
}

/// 管理画面「記憶」のノート分量表示（語数の上限は生成プロンプトの指示で、コード側の強制ではない）。
@MainActor
final class MemoryAdminViewTests: XCTestCase {
    /// 箇条書きのハイフンは語として数えない（英数字を含まないトークンを外す）。
    func testWordCountIgnoresBulletHyphens() {
        XCTAssertEqual(MemoryAdminView.wordCount("- Name is Akira."), 3)
        XCTAssertEqual(MemoryAdminView.wordCount("- Has two cats.\n- Likes coffee."), 5)
        XCTAssertEqual(MemoryAdminView.wordCount("   \n  -  \n"), 0)
        XCTAssertEqual(MemoryAdminView.wordCount(""), 0)
    }

    /// 上限は scope ごと（学習者 400 語 / キャラ 120 語）。
    func testSizeUsesScopeWordLimit() {
        let text = "- Name is Akira."
        XCTAssertEqual(
            MemoryAdminView.size(of: text, scope: .shared),
            MemoryAdminView.NoteSize(characters: 16, words: 3, limit: 400))
        XCTAssertEqual(
            MemoryAdminView.size(of: text, scope: .character(.chobi)).limit, 120)
    }

    /// 上限ちょうどは超過にしない（越えたときだけ色を変える）。
    func testIsOverLimitOnlyWhenAboveLimit() {
        let words = Array(repeating: "word", count: 120).joined(separator: " ")
        XCTAssertFalse(MemoryAdminView.size(of: words, scope: .character(.chobi)).isOverLimit)
        XCTAssertTrue(
            MemoryAdminView.size(of: words + " more", scope: .character(.chobi)).isOverLimit)
    }
}
