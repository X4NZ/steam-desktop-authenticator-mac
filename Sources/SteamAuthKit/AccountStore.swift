import Foundation

/// One `entries` record in `manifest.json`.
public struct ManifestEntry: Codable, Hashable, Sendable {
    public var iv: String?
    public var salt: String?
    public var filename: String
    public var steamID: UInt64

    enum CodingKeys: String, CodingKey {
        case iv = "encryption_iv"
        case salt = "encryption_salt"
        case filename
        case steamID = "steamid"
    }

    public init(iv: String? = nil, salt: String? = nil, filename: String, steamID: UInt64) {
        self.iv = iv
        self.salt = salt
        self.filename = filename
        self.steamID = steamID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iv = container.lenientString(.iv)
        salt = container.lenientString(.salt)
        filename = container.lenientString(.filename) ?? ""
        steamID = container.lenientUInt64(.steamID) ?? 0
    }

    public var isEncrypted: Bool { iv != nil && salt != nil }
}

/// `manifest.json`: which maFiles exist, whether they are encrypted, and the
/// app's own settings. Field names match SDA's so the file round-trips.
public struct Manifest: Codable, Sendable {
    public var encrypted: Bool = false
    public var firstRun: Bool = true
    public var entries: [ManifestEntry] = []
    public var periodicChecking: Bool = false
    public var periodicCheckingInterval: Int = 30
    public var checkAllAccounts: Bool = false
    public var autoConfirmMarketTransactions: Bool = false
    public var autoConfirmTrades: Bool = false

    enum CodingKeys: String, CodingKey {
        case encrypted
        case firstRun = "first_run"
        case entries
        case periodicChecking = "periodic_checking"
        case periodicCheckingInterval = "periodic_checking_interval"
        case checkAllAccounts = "periodic_checking_checkall"
        case autoConfirmMarketTransactions = "auto_confirm_market_transactions"
        case autoConfirmTrades = "auto_confirm_trades"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encrypted = container.lenientBool(.encrypted) ?? false
        firstRun = container.lenientBool(.firstRun) ?? true
        entries = (try? container.decodeIfPresent([ManifestEntry].self, forKey: .entries)) ?? []
        periodicChecking = container.lenientBool(.periodicChecking) ?? false
        // SDA's own default is 5 seconds, which polls Steam hard enough to
        // risk a rate limit and is not one of the intervals this app offers.
        // Clamped on the way in so the stored value and the interface agree.
        periodicCheckingInterval = max(10, container.lenientInt(.periodicCheckingInterval) ?? 30)
        checkAllAccounts = container.lenientBool(.checkAllAccounts) ?? false
        autoConfirmMarketTransactions = container.lenientBool(.autoConfirmMarketTransactions) ?? false
        autoConfirmTrades = container.lenientBool(.autoConfirmTrades) ?? false
    }
}

public enum StoreError: LocalizedError {
    case manifestUnreadable
    case accountFilesMissing([String])
    case notEncryptedButPassphraseGiven
    case passphraseRequired
    case accountHasNoSteamID
    case accountFileUnreadable(String)
    case importFailed([(filename: String, reason: String)])

    public var errorDescription: String? {
        switch self {
        case .manifestUnreadable:
            return "manifest.json could not be read. It may be corrupt; restore a backup of your maFiles folder."
        case .accountFilesMissing(let names):
            let listed = names.prefix(3).joined(separator: ", ")
            let extra = names.count > 3 ? " and \(names.count - 3) more" : ""
            return "\(listed)\(extra) listed in manifest.json but missing from disk."
        case .notEncryptedButPassphraseGiven:
            return "These maFiles are not encrypted, so no passphrase is needed."
        case .passphraseRequired:
            return "A passphrase is required to read these maFiles."
        case .accountHasNoSteamID:
            return "This account has no SteamID, so it cannot be saved."
        case .accountFileUnreadable(let name):
            return "\(name) is not a readable maFile. It may be corrupt; restore it from a backup."
        case .importFailed(let failures):
            let detail = failures
                .prefix(3)
                .map { "\($0.filename) (\($0.reason))" }
                .joined(separator: ", ")
            return "Nothing could be imported: \(detail)."
        }
    }
}

/// Reads and writes a `maFiles` directory.
///
/// The layout is SDA's: a `manifest.json` plus one `{steamid}.maFile` per
/// account. That means a folder copied off a Windows machine works here as-is,
/// and a folder written here works back on Windows.
public final class AccountStore {
    public let directory: URL
    public private(set) var manifest: Manifest

    /// Default location follows macOS convention rather than SDA's
    /// next-to-the-executable layout, which would land inside the app bundle.
    ///
    /// `SDA_MAFILES_DIR` overrides it, for keeping secrets on an encrypted
    /// volume or an external disk rather than in the home folder.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SDA_MAFILES_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SDA/maFiles", isDirectory: true)
    }

    public init(directory: URL = AccountStore.defaultDirectory) {
        self.directory = directory
        self.manifest = Manifest()
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    public var isEncrypted: Bool { manifest.encrypted }

    // MARK: - Manifest

    /// Loads the manifest, creating an empty one on first run and adopting any
    /// loose `.maFile`s that are present but unlisted.
    public func loadManifest() throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manifest = Manifest()
            try adoptLooseFiles()
            try saveManifest()
            return
        }

        let data = try Data(contentsOf: manifestURL)
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw StoreError.manifestUnreadable
        }
        manifest = decoded

        // SDA clears the flag in this case too; an empty list cannot be encrypted.
        if manifest.encrypted, manifest.entries.isEmpty {
            manifest.encrypted = false
            try saveManifest()
        }
        try adoptLooseFiles()
    }

    /// Picks up `.maFile`s that exist on disk but are not in the manifest, which
    /// is how a folder from a pre-manifest SDA version or a manual copy appears.
    private func adoptLooseFiles() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var changed = false

        for name in names where name.hasSuffix(".maFile") {
            guard !manifest.entries.contains(where: { $0.filename == name }) else { continue }

            // Only unencrypted files can be adopted: without a manifest entry
            // there is no salt or IV to decrypt with.
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let account = try? JSONDecoder().decode(SteamGuardAccount.self, from: data),
                  let steamID = account.session?.steamID, steamID != 0
            else { continue }

            manifest.entries.append(ManifestEntry(filename: name, steamID: steamID))
            changed = true
        }

        if changed { try saveManifest() }
    }

    public func saveManifest() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try write(data, to: manifestURL)
    }

    public func updateSettings(_ mutate: (inout Manifest) -> Void) throws {
        mutate(&manifest)
        try saveManifest()
    }

    // MARK: - Accounts

    /// Files the manifest lists that were not on disk during the last load.
    ///
    /// Reported rather than thrown, so the caller can name them while still
    /// showing the accounts that did load.
    public private(set) var missingFiles: [String] = []

    /// Decrypts and decodes every account in the manifest.
    ///
    /// A file missing from disk is skipped rather than fatal: one lost maFile
    /// must not cost the user access to the other nine. A file that is present
    /// but will not decrypt still throws, because that means a wrong passphrase
    /// and loading on regardless would silently drop accounts.
    public func loadAccounts(passphrase: String?) throws -> [SteamGuardAccount] {
        if manifest.encrypted, let passphrase, passphrase.isEmpty {
            throw StoreError.passphraseRequired
        }
        if manifest.encrypted, passphrase == nil {
            throw StoreError.passphraseRequired
        }

        var accounts = [SteamGuardAccount]()
        var missing = [String]()

        for entry in manifest.entries {
            let url = directory.appendingPathComponent(entry.filename)
            guard let data = try? Data(contentsOf: url) else {
                missing.append(entry.filename)
                continue
            }

            let json: Data
            if let salt = entry.salt, let iv = entry.iv, let passphrase, !passphrase.isEmpty {
                let ciphertext = String(decoding: data, as: UTF8.self)
                let plaintext = try FileEncryptor.decrypt(
                    ciphertext: ciphertext,
                    passphrase: passphrase,
                    salt: salt,
                    iv: iv
                )
                json = Data(plaintext.utf8)
            } else {
                json = data
            }

            guard var account = try? JSONDecoder().decode(SteamGuardAccount.self, from: json) else {
                // Only blame the passphrase when one was actually used.
                if entry.isEncrypted { throw CryptoError.wrongPassword }
                throw StoreError.accountFileUnreadable(entry.filename)
            }
            // Entries carry the SteamID even when the file predates sessions.
            if account.session == nil, entry.steamID != 0 {
                account.session = SessionData(steamID: entry.steamID)
            }
            accounts.append(account)
        }

        missingFiles = missing
        // Nothing at all came back: there is no partial result to show, so this
        // is worth failing on.
        if accounts.isEmpty, !missing.isEmpty {
            throw StoreError.accountFilesMissing(missing)
        }
        return accounts
    }

    /// Serialises an account, encrypting it when asked, and returns the bytes
    /// together with the manifest entry describing them.
    private func payload(
        for account: SteamGuardAccount,
        passphrase: String?,
        encrypt: Bool
    ) throws -> (entry: ManifestEntry, contents: Data) {
        guard let steamID = account.session?.steamID, steamID != 0 else {
            throw StoreError.accountHasNoSteamID
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(account)

        var entry = ManifestEntry(filename: "\(steamID).maFile", steamID: steamID)
        guard encrypt else { return (entry, json) }

        guard let passphrase, !passphrase.isEmpty else { throw StoreError.passphraseRequired }

        // Fresh salt and IV on every write, so repeated saves never reuse a
        // keystream position with the same key.
        let salt = FileEncryptor.randomSalt()
        let iv = FileEncryptor.randomIV()
        let ciphertext = try FileEncryptor.encrypt(
            plaintext: String(decoding: json, as: UTF8.self),
            passphrase: passphrase,
            salt: salt,
            iv: iv
        )
        entry.salt = salt
        entry.iv = iv
        return (entry, Data(ciphertext.utf8))
    }

    /// Writes one account, encrypting it when the store is encrypted.
    public func save(_ account: SteamGuardAccount, passphrase: String?) throws {
        let (entry, contents) = try payload(
            for: account,
            passphrase: passphrase,
            encrypt: manifest.encrypted
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(contents, to: directory.appendingPathComponent(entry.filename))

        if let index = manifest.entries.firstIndex(where: { $0.steamID == entry.steamID }) {
            manifest.entries[index] = entry
        } else {
            manifest.entries.append(entry)
        }
        manifest.firstRun = false
        try saveManifest()
    }

    /// Removes an account from the manifest and deletes its maFile.
    ///
    /// This only forgets the account locally; it does not touch Steam. Removing
    /// an account whose authenticator is still active means losing the secrets.
    public func forget(steamID: UInt64) throws {
        guard let index = manifest.entries.firstIndex(where: { $0.steamID == steamID }) else { return }
        let entry = manifest.entries[index]
        manifest.entries.remove(at: index)
        if manifest.entries.isEmpty { manifest.encrypted = false }
        try saveManifest()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
    }

    // MARK: - Encryption changes

    /// Re-encrypts every account under a new passphrase (or removes encryption
    /// when `newPassphrase` is nil).
    ///
    /// Every file is encrypted in memory and staged beside its target before any
    /// of them is replaced, so a failure half way through cannot leave the folder
    /// with some files under the old key and some under the new one — which no
    /// single passphrase could then open.
    public func changeEncryption(currentPassphrase: String?, newPassphrase: String?) throws {
        let accounts = try loadAccounts(passphrase: currentPassphrase)
        let encrypt = (newPassphrase?.isEmpty == false)

        var staged: [(entry: ManifestEntry, temporary: URL, final: URL)] = []

        func discardStaged() {
            for item in staged { try? FileManager.default.removeItem(at: item.temporary) }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            for account in accounts {
                let (entry, contents) = try payload(
                    for: account,
                    passphrase: newPassphrase,
                    encrypt: encrypt
                )
                let temporary = directory.appendingPathComponent(entry.filename + ".new")
                try write(contents, to: temporary)
                staged.append((entry, temporary, directory.appendingPathComponent(entry.filename)))
            }
        } catch {
            // Nothing has been replaced yet, so the folder is untouched.
            discardStaged()
            throw error
        }

        // Past this point files are being replaced. Keep a copy of each
        // original first, so a swap that fails half way can be undone rather
        // than leaving the folder split across two passphrases.
        var backups: [(original: URL, backup: URL)] = []
        var replaced: [URL] = []

        do {
            for item in staged where FileManager.default.fileExists(atPath: item.final.path) {
                let backup = directory.appendingPathComponent(item.entry.filename + ".bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: item.final, to: backup)
                backups.append((item.final, backup))
            }

            for item in staged {
                _ = try FileManager.default.replaceItemAt(item.final, withItemAt: item.temporary)
                replaced.append(item.final)
            }
        } catch {
            for entry in backups where replaced.contains(entry.original) {
                try? FileManager.default.removeItem(at: entry.original)
                try? FileManager.default.moveItem(at: entry.backup, to: entry.original)
            }
            for entry in backups { try? FileManager.default.removeItem(at: entry.backup) }
            discardStaged()
            throw error
        }

        for entry in backups { try? FileManager.default.removeItem(at: entry.backup) }

        manifest.encrypted = encrypt
        for item in staged {
            if let index = manifest.entries.firstIndex(where: { $0.steamID == item.entry.steamID }) {
                manifest.entries[index] = item.entry
            } else {
                manifest.entries.append(item.entry)
            }
        }
        try saveManifest()
    }

    /// Verifies a passphrase without keeping anything decrypted.
    public func verify(passphrase: String) -> Bool {
        (try? loadAccounts(passphrase: passphrase)) != nil
    }

    // MARK: - Import

    /// Imports an maFile from anywhere on disk into the store.
    ///
    /// `sourcePassphrase` decrypts the incoming file when it came from an
    /// encrypted SDA install; the file is then re-saved under this store's own
    /// encryption settings.
    public func importMaFile(
        at url: URL,
        sourcePassphrase: String?,
        sourceSalt: String? = nil,
        sourceIV: String? = nil,
        storePassphrase: String?
    ) throws -> SteamGuardAccount {
        let data = try Data(contentsOf: url)
        var json = data

        if let sourcePassphrase, !sourcePassphrase.isEmpty, let sourceSalt, let sourceIV {
            let plaintext = try FileEncryptor.decrypt(
                ciphertext: String(decoding: data, as: UTF8.self),
                passphrase: sourcePassphrase,
                salt: sourceSalt,
                iv: sourceIV
            )
            json = Data(plaintext.utf8)
        }

        guard let account = try? JSONDecoder().decode(SteamGuardAccount.self, from: json) else {
            throw CryptoError.wrongPassword
        }
        try save(account, passphrase: storePassphrase)
        return account
    }

    /// What a folder import managed to do.
    ///
    /// Partial success is reported rather than thrown: one unreadable file (an
    /// iCloud placeholder that is not downloaded, say) should not cost the user
    /// the other nine accounts in the folder.
    public struct ImportSummary: Sendable {
        public var imported: [SteamGuardAccount] = []
        public var skipped: [(filename: String, reason: String)] = []

        public var isEmpty: Bool { imported.isEmpty }
    }

    /// Imports a whole `maFiles` folder: reads its manifest for the per-file
    /// salts and IVs, then re-saves each account into this store.
    ///
    /// Any `.maFile` on disk that the manifest does not list is picked up too,
    /// since folders copied by hand often lose manifest entries.
    @discardableResult
    public func importFolder(
        at url: URL,
        sourcePassphrase: String?,
        storePassphrase: String?
    ) throws -> ImportSummary {
        let sourceManifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: sourceManifestURL),
              let sourceManifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw StoreError.manifestUnreadable }

        var summary = ImportSummary()
        var seen = Set<String>()

        for entry in sourceManifest.entries {
            seen.insert(entry.filename)
            let fileURL = url.appendingPathComponent(entry.filename)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                summary.skipped.append((entry.filename, "missing from the folder"))
                continue
            }

            do {
                let account = try importMaFile(
                    at: fileURL,
                    sourcePassphrase: entry.isEncrypted ? sourcePassphrase : nil,
                    sourceSalt: entry.salt,
                    sourceIV: entry.iv,
                    storePassphrase: storePassphrase
                )
                summary.imported.append(account)
            } catch {
                summary.skipped.append((entry.filename, reason(for: error, url: fileURL)))
            }
        }

        // Unlisted .maFiles: only plain ones can be read, having no salt.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where name.hasSuffix(".maFile") && !seen.contains(name) {
            do {
                let account = try importMaFile(
                    at: url.appendingPathComponent(name),
                    sourcePassphrase: nil,
                    storePassphrase: storePassphrase
                )
                summary.imported.append(account)
            } catch {
                summary.skipped.append((name, "not listed in manifest.json and not readable"))
            }
        }

        // Only a total failure is worth throwing over.
        if summary.imported.isEmpty, !summary.skipped.isEmpty {
            throw StoreError.importFailed(summary.skipped)
        }
        return summary
    }

    /// Turns a read failure into something worth showing the user.
    private func reason(for error: Error, url: URL) -> String {
        if error is CryptoError { return "wrong passphrase, or not a valid maFile" }

        // An iCloud/Drive file that has not been downloaded reads as missing.
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true {
            return "stored in iCloud and not downloaded to this Mac"
        }
        return error.localizedDescription
    }

    // MARK: - Disk

    /// Writes with an owner-only file mode: these files are the account.
    ///
    /// The mode is set on the temporary file before any bytes are written to
    /// it, rather than on the destination afterwards: writing atomically and
    /// then chmod-ing leaves the secrets briefly readable at whatever the
    /// umask allows.
    private func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).writing")
        try? FileManager.default.removeItem(at: temporary)

        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }

        do {
            try data.write(to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        // replaceItemAt can carry the destination's old mode across.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
