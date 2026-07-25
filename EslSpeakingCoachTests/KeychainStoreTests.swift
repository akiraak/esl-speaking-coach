import XCTest
@testable import EslSpeakingCoach

final class KeychainStoreTests: XCTestCase {
    private let keychain = KeychainStore()
    private let account = "test-api-key"
    private let secondAccount = "test-api-key-2"

    override func tearDownWithError() throws {
        try keychain.delete(account: account)
        try keychain.delete(account: secondAccount)
    }

    func testReadReturnsNilWhenMissing() throws {
        XCTAssertNil(try keychain.read(account: account))
    }

    func testSaveAndRead() throws {
        try keychain.save("secret-1", account: account)
        XCTAssertEqual(try keychain.read(account: account), "secret-1")
    }

    func testOverwriteReplacesValue() throws {
        try keychain.save("secret-1", account: account)
        try keychain.save("secret-2", account: account)
        XCTAssertEqual(try keychain.read(account: account), "secret-2")
    }

    func testDeleteRemovesValue() throws {
        try keychain.save("secret-1", account: account)
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
    }

    func testDeleteMissingDoesNotThrow() throws {
        XCTAssertNoThrow(try keychain.delete(account: account))
    }

    func testAccountsAreIsolated() throws {
        try keychain.save("secret-a", account: account)
        try keychain.save("secret-b", account: secondAccount)
        XCTAssertEqual(try keychain.read(account: account), "secret-a")
        XCTAssertEqual(try keychain.read(account: secondAccount), "secret-b")
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
        XCTAssertEqual(try keychain.read(account: secondAccount), "secret-b")
    }
}
