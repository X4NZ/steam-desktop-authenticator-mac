import Foundation
import Testing

@testable import SteamAuthKit

/// Exercises the storage layer against real folders in a temp directory, since
/// its whole job is staying compatible with what SDA writes to disk.
struct AccountStoreTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleAccount(name: String, steamID: UInt64) -> SteamGuardAccount {
        var account = SteamGuardAccount()
        account.accountName = name
        account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
        account.identitySecret = "AqoNZ1QXm1uJMqiMcLxJ6RtJVXE="
        account.revocationCode = "R12345"
        account.deviceID = "android:0000-1111"
        account.session = SessionData(steamID: steamID)
        return account
    }

    @Test("Saving then loading round-trips an account")
    func roundTrip() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "alice", steamID: 7_656_119_800_000_0001), passphrase: nil)

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        let accounts = try reopened.loadAccounts(passphrase: nil)

        #expect(accounts.count == 1)
        #expect(accounts[0].accountName == "alice")
        #expect(accounts[0].generateCode(forTime: 1_616_374_841) == "2F9J5")
    }

    @Test("maFiles are written with the filename SDA expects")
    func filenameMatchesSDA() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "bob", steamID: 76_561_198_000_000_002), passphrase: nil)

        let path = directory.appendingPathComponent("76561198000000002.maFile")
        #expect(FileManager.default.fileExists(atPath: path.path))

        // The Session key is capitalised in SDA's output; ours must match.
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("\"Session\""))
        #expect(text.contains("\"shared_secret\""))
    }

    @Test("Secrets are written owner-only")
    func filePermissions() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "carol", steamID: 76_561_198_000_000_003), passphrase: nil)

        let path = directory.appendingPathComponent("76561198000000003.maFile").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test("Encrypting, then reading back, needs the right passphrase")
    func encryptionRoundTrip() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "dave", steamID: 76_561_198_000_000_004), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "hunter2")

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(reopened.isEncrypted)
        #expect(throws: Error.self) { try reopened.loadAccounts(passphrase: "wrong") }

        let accounts = try reopened.loadAccounts(passphrase: "hunter2")
        #expect(accounts.count == 1)
        #expect(accounts[0].accountName == "dave")
    }

    @Test("Removing encryption leaves readable files behind")
    func removeEncryption() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "erin", steamID: 76_561_198_000_000_005), passphrase: nil)
        try store.changeEncryption(currentPassphrase: nil, newPassphrase: "pass")
        try store.changeEncryption(currentPassphrase: "pass", newPassphrase: nil)

        let reopened = AccountStore(directory: directory)
        try reopened.loadManifest()
        #expect(!reopened.isEncrypted)
        #expect(try reopened.loadAccounts(passphrase: nil).count == 1)
    }

    @Test("A folder import brings every account across")
    func folderImport() throws {
        let source = makeTempDirectory()
        let destination = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let origin = AccountStore(directory: source)
        try origin.loadManifest()
        try origin.save(sampleAccount(name: "frank", steamID: 76_561_198_000_000_006), passphrase: nil)
        try origin.save(sampleAccount(name: "grace", steamID: 76_561_198_000_000_007), passphrase: nil)

        let store = AccountStore(directory: destination)
        try store.loadManifest()
        let summary = try store.importFolder(at: source, sourcePassphrase: nil, storePassphrase: nil)

        #expect(summary.imported.count == 2)
        #expect(summary.skipped.isEmpty)
        #expect(Set(summary.imported.compactMap(\.accountName)) == ["frank", "grace"])
    }

    @Test("An encrypted folder imports with its passphrase")
    func encryptedFolderImport() throws {
        let source = makeTempDirectory()
        let destination = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let origin = AccountStore(directory: source)
        try origin.loadManifest()
        try origin.save(sampleAccount(name: "heidi", steamID: 76_561_198_000_000_008), passphrase: nil)
        try origin.changeEncryption(currentPassphrase: nil, newPassphrase: "source-pass")

        let store = AccountStore(directory: destination)
        try store.loadManifest()
        let summary = try store.importFolder(
            at: source, sourcePassphrase: "source-pass", storePassphrase: nil
        )

        #expect(summary.imported.count == 1)
        #expect(summary.imported[0].accountName == "heidi")
        #expect(summary.imported[0].sharedSecret == "zvIayp3JPvtvX/QGHqsqKBk/44s=")
    }

    @Test("One unreadable file does not sink the whole import")
    func partialImport() throws {
        let source = makeTempDirectory()
        let destination = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let origin = AccountStore(directory: source)
        try origin.loadManifest()
        try origin.save(sampleAccount(name: "ivan", steamID: 76_561_198_000_000_009), passphrase: nil)
        try origin.save(sampleAccount(name: "judy", steamID: 76_561_198_000_000_010), passphrase: nil)

        // Stands in for an iCloud placeholder or a corrupt file.
        try FileManager.default.removeItem(
            at: source.appendingPathComponent("76561198000000010.maFile")
        )

        let store = AccountStore(directory: destination)
        try store.loadManifest()
        let summary = try store.importFolder(at: source, sourcePassphrase: nil, storePassphrase: nil)

        #expect(summary.imported.count == 1)
        #expect(summary.imported[0].accountName == "ivan")
        #expect(summary.skipped.count == 1)
        #expect(summary.skipped[0].filename == "76561198000000010.maFile")
    }

    @Test("Loose maFiles with no manifest entry are still picked up")
    func adoptsLooseFiles() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = sampleAccount(name: "ken", steamID: 76_561_198_000_000_011)
        let data = try JSONEncoder().encode(account)
        try data.write(to: directory.appendingPathComponent("76561198000000011.maFile"))

        let store = AccountStore(directory: directory)
        try store.loadManifest()

        #expect(store.manifest.entries.count == 1)
        #expect(try store.loadAccounts(passphrase: nil).first?.accountName == "ken")
    }

    @Test("Forgetting an account deletes its file")
    func forget() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        try store.loadManifest()
        try store.save(sampleAccount(name: "lena", steamID: 76_561_198_000_000_012), passphrase: nil)
        try store.forget(steamID: 76_561_198_000_000_012)

        #expect(store.manifest.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("76561198000000012.maFile").path
            )
        )
    }
}
