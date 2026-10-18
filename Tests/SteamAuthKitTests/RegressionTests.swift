import Foundation
import Testing

@testable import SteamAuthKit

/// One test per fixed defect, named for the behaviour that regressed.
struct AccountIdentityTests {

    @Test("An account's id is stable across reads")
    func idIsStable() {
        // It used to fall back to a fresh UUID, so every read returned a
        // different identity and list selection could never match.
        var account = SteamGuardAccount()
        account.session = SessionData(steamID: 76_561_198_000_000_001)

        let first = account.id
        #expect(account.id == first)
        #expect(account.id == first)
        #expect(first == "76561198000000001")
    }

    @Test("Identity prefers the account name, then token, then SteamID")
    func idPrecedence() {
        var account = SteamGuardAccount()
        account.session = SessionData(steamID: 5)
        #expect(account.id == "5")

        account.tokenGID = "gid123"
        #expect(account.id == "gid123")

        account.accountName = "alice"
        #expect(account.id == "alice")
    }

    @Test("An account with nothing identifying still returns a constant")
    func idFallback() {
        let account = SteamGuardAccount()
        #expect(account.id == account.id)
    }
}

struct SessionCookieTests {

    @Test("The session id is settled once, not regenerated per call")
    func sessionIDIsStable() {
        // cookieHeader() used to be mutating and generate the id on a throwaway
        // copy, so every request carried a different sessionid.
        let session = SessionData(steamID: 76_561_198_000_000_001, accessToken: "token")

        let first = session.cookieHeader()
        let second = session.cookieHeader()
        #expect(first == second)
        #expect(session.sessionID?.isEmpty == false)
    }

    @Test("A decoded session without a stored id gets one")
    func decodedSessionGetsID() throws {
        let json = #"{"SteamID":76561198000000001,"AccessToken":"a","RefreshToken":"b"}"#
        let session = try JSONDecoder().decode(SessionData.self, from: Data(json.utf8))
        #expect(session.sessionID?.isEmpty == false)
    }

    @Test("Cookies carry what the mobile confirmation pages expect")
    func cookieContents() {
        let session = SessionData(steamID: 76_561_198_000_000_001, accessToken: "tok")
        let header = session.cookieHeader()

        #expect(header.contains("steamLoginSecure=76561198000000001%7C%7Ctok"))
        #expect(header.contains("mobileClient=android"))
        #expect(header.contains("sessionid="))
    }
}

struct EncryptionChangeTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-regress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ name: String, _ steamID: UInt64) -> SteamGuardAccount {
        var account = SteamGuardAccount()
        account.accountName = name
        account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
        account.identitySecret = "AqoNZ1QXm1uJMqiMcLxJ6RtJVXE="
        account.session = SessionData(steamID: steamID)
        return account
    }

    @Test("Every account ends up under the new passphrase, not just some")
    func allAccountsReEncrypted() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for index in 1 ... 5 {
            try store.save(account("user\(index)", UInt64(76_561_198_000_000_000 + index)), passphrase: nil)
        }

        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "newpass")

        // The whole folder must open with one passphrase; a partial re-encrypt
        // used to leave some files under the old key and some under the new.
        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(reopened.isEncrypted)

        let accounts = try reopened.loadAccounts(passphrase: "newpass")
        #expect(accounts.count == 5)
        #expect(accounts.allSatisfy { $0.sharedSecret == "zvIayp3JPvtvX/QGHqsqKBk/44s=" })
    }

    @Test("Every manifest entry gets its own salt and IV")
    func entriesHaveDistinctSalts() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for index in 1 ... 3 {
            try store.save(account("user\(index)", UInt64(76_561_198_000_000_000 + index)), passphrase: nil)
        }
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "pass")

        let salts = store.manifest.entries.compactMap(\.salt)
        let ivs = store.manifest.entries.compactMap(\.iv)
        #expect(salts.count == 3)
        #expect(Set(salts).count == 3)
        #expect(Set(ivs).count == 3)
    }

    @Test("A failed re-encryption leaves the folder exactly as it was")
    func failureLeavesFolderIntact() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("user1", 76_561_198_000_000_001), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "right")

        let before = try Data(
            contentsOf: directory.appendingPathComponent("76561198000000001.maFile")
        )

        // Wrong current passphrase: this must fail before touching anything.
        #expect(throws: Error.self) {
            try store.changeEncryption(currentPassphrase: "wrong", newPassphrase: "other")
        }

        let after = try Data(
            contentsOf: directory.appendingPathComponent("76561198000000001.maFile")
        )
        #expect(before == after)

        // And the original passphrase still opens it.
        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(try reopened.loadAccounts(passphrase: "right").count == 1)
    }

    @Test("No staging files are left behind")
    func noLeftoverTempFiles() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("user1", 76_561_198_000_000_001), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "pass")

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix(".new") })
    }

    @Test("A corrupt plaintext file is not blamed on the passphrase")
    func corruptFileIsReportedAsSuch() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("user1", 76_561_198_000_000_001), passphrase: nil)

        try Data("not json at all".utf8).write(
            to: directory.appendingPathComponent("76561198000000001.maFile")
        )

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()

        do {
            _ = try reopened.loadAccounts(passphrase: nil)
            Issue.record("expected a failure")
        } catch let error as StoreError {
            guard case .accountFileUnreadable = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }
}
