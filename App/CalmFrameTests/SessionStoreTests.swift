import XCTest

@testable import CalmFrame

/// SessionStore：存 / 恢复 / 清除，Keychain 用内存替身，不碰真 Keychain。
@MainActor
final class SessionStoreTests: XCTestCase {

    func testSaveRestoreClear() {
        let keychain = InMemoryKeychainStore()
        let store = SessionStore(keychain: keychain)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.serverToken)
        XCTAssertNil(store.balance)

        store.save(token: "jwt-1", appleSub: "sub-1", balance: 5)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.serverToken, "jwt-1")
        XCTAssertEqual(store.appleSub, "sub-1")
        XCTAssertEqual(store.balance, 5)

        // 同一个 Keychain 起的新实例能恢复出来（模拟重启 App）。
        let restored = SessionStore(keychain: keychain)
        XCTAssertTrue(restored.isSignedIn)
        XCTAssertEqual(restored.serverToken, "jwt-1")
        XCTAssertEqual(restored.appleSub, "sub-1")
        XCTAssertEqual(restored.balance, 5)

        restored.clear()
        XCTAssertFalse(restored.isSignedIn)
        XCTAssertNil(restored.serverToken)
        XCTAssertNil(restored.balance)
        XCTAssertNil(keychain.string(forKey: "serverToken"))
        XCTAssertNil(keychain.string(forKey: "appleSub"))
        XCTAssertNil(keychain.string(forKey: "balance"))
    }

    func testUpdateBalance() {
        let keychain = InMemoryKeychainStore()
        let store = SessionStore(keychain: keychain)
        store.save(token: "jwt-1", appleSub: "sub-1", balance: 5)
        store.updateBalance(3)
        XCTAssertEqual(store.balance, 3)
        XCTAssertEqual(SessionStore(keychain: keychain).balance, 3)
    }
}
