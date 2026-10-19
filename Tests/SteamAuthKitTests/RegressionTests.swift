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
            guard case .accountFilesDamaged = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }
}

/// Second review pass: parsing, store resilience and on-disk permissions.
struct SecondReviewTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-rev2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ name: String, steamID: UInt64) -> SteamGuardAccount {
        var account = SteamGuardAccount()
        account.accountName = name
        account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
        account.session = SessionData(steamID: steamID)
        return account
    }

    @Test("A length-delimited field larger than Int.max is rejected, not fatal")
    func oversizedLengthIsRejected() {
        // Int(length) used to trap here, so any malformed response crashed the
        // app rather than being treated as unparseable.
        var bytes: [UInt8] = [0x0A] // field 1, length-delimited
        bytes += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]

        let message = ProtoMessage(Data(bytes))
        #expect(message.bytes(1) == nil)
    }

    @Test("Fields before an oversized one still parse")
    func parsingStopsCleanlyAtTheBadField() {
        var bytes: [UInt8] = [0x08, 0x2A] // field 1 varint = 42
        bytes += [0x12] // field 2, length-delimited
        bytes += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]

        let message = ProtoMessage(Data(bytes))
        #expect(message.varint(1) == 42)
        #expect(message.bytes(2) == nil)
    }

    @Test("One missing maFile does not hide the other accounts")
    func oneMissingFileLeavesTheRestReadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for steamID in UInt64(1) ... 3 {
            try store.save(account("account\(steamID)", steamID: steamID), passphrase: nil)
        }

        // Losing one file used to throw, which cost the user all three.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("2.maFile"))

        let loaded = try store.loadAccounts(passphrase: nil)
        #expect(loaded.count == 2)
        #expect(store.missingFiles == ["2.maFile"])
    }

    @Test("Losing every maFile is still an error")
    func losingEverythingStillThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("solo", steamID: 7), passphrase: nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("7.maFile"))

        #expect(throws: StoreError.self) { try store.loadAccounts(passphrase: nil) }
    }

    @Test("A wrong passphrase is still an error, not a partial load")
    func wrongPassphraseStillThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("alice", steamID: 11), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "right")

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(throws: Error.self) { try reopened.loadAccounts(passphrase: "wrong") }
    }

    @Test("maFiles are never readable by anyone but their owner")
    func filesAreOwnerOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("alice", steamID: 99), passphrase: nil)
        // Saved twice: the second write goes down the replace path rather than
        // the create path, and that one used to re-expose the file.
        try store.save(account("alice", steamID: 99), passphrase: nil)

        let path = directory.appendingPathComponent("99.maFile").path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test("No staging or backup files survive a re-encryption")
    func reEncryptionLeavesNoDebris() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("alice", steamID: 21), passphrase: nil)
        try store.save(account("bob", steamID: 22), passphrase: nil)

        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "s3cret")

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix(".new") || $0.hasSuffix(".bak") })
        #expect(try store.loadAccounts(passphrase: "s3cret").count == 2)
    }

    @Test("An escaped identity secret still signs confirmations")
    func escapedIdentitySecretIsUnescaped() {
        // shared_secret was already unescaped, identity_secret was not, so an
        // maFile written with escaped slashes generated codes but could not
        // sign a single confirmation.
        let raw = "zvIayp3JPvtvX/QGHqsqKBk/44s="
        var plain = SteamGuardAccount()
        plain.identitySecret = raw

        var escaped = SteamGuardAccount()
        escaped.identitySecret = raw.replacingOccurrences(of: "/", with: "\\/")

        let expected = plain.confirmationHash(forTime: 1_600_000_000, tag: "list")
        #expect(expected != nil)
        #expect(escaped.confirmationHash(forTime: 1_600_000_000, tag: "list") == expected)
    }
}

/// Steam's two ways of reporting failure, which used to be read as success.
struct ResponseCheckingTests {

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.steampowered.com/x")!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: headers
        )!
    }

    @Test("An OK eresult passes")
    func okEresultPasses() throws {
        // What QueryTime and GetPasswordRSAPublicKey actually send back.
        try SteamWeb.check(response(status: 200, headers: ["x-eresult": "1"]))
    }

    @Test("A failing eresult is surfaced with its message")
    func failingEresultThrows() {
        #expect(throws: SteamError.self) {
            try SteamWeb.check(response(
                status: 200,
                headers: ["x-eresult": "5", "x-error_message": "invalid password"]
            ))
        }
    }

    @Test("A server error without an eresult header is not treated as success")
    func serverErrorWithoutHeaderThrows() {
        // This was the gap: a 503 carrying an HTML error page parsed as an
        // empty protobuf message, and login reported bad credentials instead
        // of Steam being down.
        #expect(throws: SteamError.self) { try SteamWeb.check(response(status: 503)) }
        #expect(throws: SteamError.self) { try SteamWeb.check(response(status: 429)) }
    }

    @Test("A plain 200 without the header still passes")
    func plainSuccessPasses() throws {
        // The /mobileconf/ pages send no eresult header at all.
        try SteamWeb.check(response(status: 200))
    }
}

/// Third pass: defects found reviewing the second pass's own fixes.
struct ThirdReviewTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-rev3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ name: String, steamID: UInt64) -> SteamGuardAccount {
        var account = SteamGuardAccount()
        account.accountName = name
        account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
        account.session = SessionData(steamID: steamID)
        return account
    }

    @Test("A length just under Int.max is rejected without trapping")
    func lengthNearIntMaxIsRejected() {
        // Int(exactly:) admits this, and `offset + count` then overflowed. The
        // leading varint matters: it leaves offset non-zero at the bad field.
        var bytes: [UInt8] = [0x08, 0x2A, 0x12]
        bytes += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F] // Int.max

        let message = ProtoMessage(Data(bytes))
        #expect(message.varint(1) == 42)
        #expect(message.bytes(2) == nil)
    }

    @Test("Every oversized length is rejected, whatever the offset")
    func oversizedLengthsAtAnyOffsetAreRejected() {
        let lengths: [[UInt8]] = [
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], // UInt64.max
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],       // Int.max
            [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40],       // 2^62
            [0xFF, 0xFF, 0xFF, 0xFF, 0x0F],                               // 2^32-1
        ]

        for length in lengths {
            for padding in 0 ... 3 {
                var bytes = [UInt8](repeating: 0x08, count: 0)
                for _ in 0 ..< padding { bytes += [0x08, 0x01] }
                bytes += [0x12] + length
                #expect(ProtoMessage(Data(bytes)).bytes(2) == nil)
            }
        }
    }

    @Test("A passphrase change is refused while a maFile is unreadable")
    func reKeyingRefusesWithAMissingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for steamID in UInt64(1) ... 2 {
            try store.save(account("account\(steamID)", steamID: steamID), passphrase: nil)
        }
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "first")

        // An iCloud maFile that has not finished downloading reads as absent.
        let away = directory.appendingPathComponent("2.maFile.stashed")
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("2.maFile"), to: away
        )

        // Re-keying used to carry on, leaving that entry with its old salt.
        #expect(throws: StoreError.self) {
            try store.changeEncryption(currentPassphrase: "first", newPassphrase: "second")
        }

        // It comes back, and the original passphrase still opens everything.
        try FileManager.default.moveItem(
            at: away, to: directory.appendingPathComponent("2.maFile")
        )
        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(try reopened.loadAccounts(passphrase: "first").count == 2)
    }

    @Test("missingFiles describes the load that just ran, not an older one")
    func missingFilesIsNotStale() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(account("alice", steamID: 1), passphrase: nil)
        try store.save(account("bob", steamID: 2), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "right")

        let away = directory.appendingPathComponent("2.maFile.stashed")
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("2.maFile"), to: away
        )
        _ = try store.loadAccounts(passphrase: "right")
        #expect(store.missingFiles == ["2.maFile"])

        // Put it back and load with the wrong passphrase, which throws part way.
        try FileManager.default.moveItem(
            at: away, to: directory.appendingPathComponent("2.maFile")
        )
        #expect(throws: Error.self) { try store.loadAccounts(passphrase: "wrong") }
        #expect(store.missingFiles.isEmpty, "a failed load must not keep the old list")
    }

    @Test("Form-encoded requests judge only the HTTP status")
    func formRequestsIgnoreEresult() throws {
        // AddAuthenticator reports status 2 and 29 in the body as expected
        // outcomes. Enforcing x-eresult here made those branches unreachable.
        let url = URL(string: "https://api.steampowered.com/x")!
        let withEresult = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/2",
            headerFields: ["x-eresult": "2"]
        )!
        try SteamWeb.checkStatus(withEresult)

        let serverError = HTTPURLResponse(
            url: url, statusCode: 503, httpVersion: "HTTP/2", headerFields: [:]
        )!
        #expect(throws: SteamError.self) { try SteamWeb.checkStatus(serverError) }
    }
}

/// Fourth pass: telling a damaged file apart from a wrong passphrase.
struct FourthReviewTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-rev4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func populated(_ directory: URL, count: UInt64, passphrase: String?) throws -> AccountStore {
        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for steamID in 1 ... count {
            var account = SteamGuardAccount()
            account.accountName = "account\(steamID)"
            account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
            account.session = SessionData(steamID: steamID)
            try store.save(account, passphrase: nil)
        }
        if let passphrase {
            try store.changeEncryption(currentPassphrase: nil, newPassphrase: passphrase)
        }
        return store
    }

    @Test("A correct passphrase is not blamed for one damaged file")
    func correctPassphraseSurvivesOneDamagedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try populated(directory, count: 3, passphrase: "correct")

        // Bit rot, a half-finished sync, a botched manual edit.
        try Data("not valid ciphertext".utf8)
            .write(to: directory.appendingPathComponent("2.maFile"))

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()

        // This used to throw .wrongPassword, so the unlock screen told the user
        // their correct passphrase was wrong and nothing got them past it.
        let loaded = try reopened.loadAccounts(passphrase: "correct")
        #expect(loaded.count == 2)
        #expect(reopened.damagedFiles == ["2.maFile"])
        #expect(reopened.unreadableFiles == ["2.maFile"])
    }

    @Test("A genuinely wrong passphrase is still a wrong passphrase")
    func wrongPassphraseStillReportsItself() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try populated(directory, count: 3, passphrase: "correct")

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()

        do {
            _ = try reopened.loadAccounts(passphrase: "wrong")
            Issue.record("expected a failure")
        } catch let error as CryptoError {
            guard case .wrongPassword = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test("Re-keying is refused over a damaged file, not just a missing one")
    func reKeyingRefusesOverDamage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try populated(directory, count: 2, passphrase: "first")

        try Data("ruined".utf8).write(to: directory.appendingPathComponent("2.maFile"))

        #expect(throws: StoreError.self) {
            try store.changeEncryption(currentPassphrase: "first", newPassphrase: "second")
        }
        // The readable account still opens under the untouched passphrase.
        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(try reopened.loadAccounts(passphrase: "first").count == 1)
    }

    @Test("Dropping unreadable entries unblocks a passphrase change")
    func droppingEntriesUnblocksReKeying() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try populated(directory, count: 2, passphrase: "first")

        // Gone for good: a failed restore, or deleted by hand.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("2.maFile"))
        _ = try store.loadAccounts(passphrase: "first")
        #expect(store.missingFiles == ["2.maFile"])

        // Without this the store could never be re-keyed again, and the error
        // could only tell the user to restore a file that no longer exists.
        let dropped = try store.forgetUnreadableEntries()
        #expect(dropped == ["2.maFile"])
        #expect(store.unreadableFiles.isEmpty)

        try store.changeEncryption(currentPassphrase: "first", newPassphrase: "second")
        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(try reopened.loadAccounts(passphrase: "second").count == 1)
    }

    @Test("Dropping an entry leaves the file itself alone")
    func droppingEntriesKeepsTheFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try populated(directory, count: 2, passphrase: "first")

        let damaged = directory.appendingPathComponent("2.maFile")
        try Data("ruined".utf8).write(to: damaged)
        _ = try store.loadAccounts(passphrase: "first")

        _ = try store.forgetUnreadableEntries()
        // It may still be worth recovering by hand, so it must survive.
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }
}

/// Fifth pass: a mistyped passphrase must not look like a damaged store.
struct FifthReviewTests {

    private func encryptedStore(
        _ directory: URL,
        count: UInt64,
        passphrase: String
    ) throws -> AccountStore {
        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for steamID in 1 ... count {
            var account = SteamGuardAccount()
            account.accountName = "account\(steamID)"
            account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
            account.session = SessionData(steamID: steamID)
            try store.save(account, passphrase: nil)
        }
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: passphrase)
        return store
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-rev5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A mistyped passphrase does not mark the whole store damaged")
    func typoDoesNotCondemnTheStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try encryptedStore(directory, count: 3, passphrase: "correct")

        // Anywhere that calls verify() — the Touch ID field in Settings does.
        #expect(!store.verify(passphrase: "typo"))

        // Every file failed to decrypt, but that is evidence about the
        // passphrase, not about the files. Publishing it let the interface
        // offer to drop all three manifest entries, and the salts live only in
        // manifest.json, so that made the ciphertext unrecoverable.
        #expect(store.damagedFiles.isEmpty)
        #expect(store.unreadableFiles.isEmpty)
        #expect(try store.forgetUnreadableEntries().isEmpty)
        #expect(try store.loadAccounts(passphrase: "correct").count == 3)
    }

    @Test("Damage is still reported when the passphrase is proven right")
    func damageIsReportedOnceThePassphraseIsProven() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try encryptedStore(directory, count: 3, passphrase: "correct")

        try Data("ruined".utf8).write(to: directory.appendingPathComponent("2.maFile"))
        #expect(try store.loadAccounts(passphrase: "correct").count == 2)
        #expect(store.damagedFiles == ["2.maFile"])
    }

    @Test("A single damaged file is not reported as damage it cannot prove")
    func loneDamagedFileStaysAmbiguous() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try encryptedStore(directory, count: 1, passphrase: "correct")

        try Data("ruined".utf8).write(to: directory.appendingPathComponent("1.maFile"))

        // Nothing opened, so this is indistinguishable from a wrong
        // passphrase. It must resolve towards safety: no damage list, so
        // nothing offers to delete the entry.
        #expect(throws: CryptoError.self) { try store.loadAccounts(passphrase: "correct") }
        #expect(store.damagedFiles.isEmpty)
        #expect(try store.forgetUnreadableEntries().isEmpty)
    }

    @Test("Dropping entries keeps the previous manifest beside it")
    func droppingEntriesBacksUpTheManifest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try encryptedStore(directory, count: 2, passphrase: "first")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("2.maFile"))
        _ = try store.loadAccounts(passphrase: "first")
        _ = try store.forgetUnreadableEntries()

        // The dropped entry's salt is only recoverable from this copy.
        let backup = directory.appendingPathComponent("manifest.json.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))

        let previous = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: backup))
        #expect(previous.entries.count == 2)
        #expect(previous.entries.contains { $0.filename == "2.maFile" && $0.salt != nil })
    }
}
