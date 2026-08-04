import XCTest
@testable import EslSpeakingCoach

/// 管理画面ルートの構成（docs/plans/model-selection-in-admin.md Phase 1）。
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
            ["会話", "記憶", "料金", "診断", "容量", "モデル"])
    }
}
