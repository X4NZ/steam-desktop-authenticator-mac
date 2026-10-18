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
    public var periodicCheckingInterval: Int = 5
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
        periodicCheckingInterval = container.lenientInt(.periodicCheckingInterval) ?? 5
        checkAllAccounts = container.lenientBool(.checkAllAccounts) ?? false
        autoConfirmMarketTransactions = container.lenientBool(.autoConfirmMarketTransactions) ?? false
        autoConfirmTrades = container.lenientBool(.autoConfirmTrades) ?? false
    }
}

public enum StoreError: LocalizedError {
    case manifestUnreadable
    case accountFileMissing(String)
    case notEncryptedButPassphraseGiven
    case passphraseRequired
    case accountHasNoSteamID

    public var errorDescription: String? {
        switch self {
        case .manifestUnreadable:
            return "manifest.json could not be read. It may be corrupt; restore a backup of your maFiles folder."
        case .accountFileMissing(let name):
            return "The file \(name) is listed in manifest.json but missing from disk."
        case .notEncryptedButPassphraseGiven:
            return "These maFiles are not encrypted, so no passphrase is needed."
        case .passphraseRequired:
            return "A passphrase is required to read these maFiles."
        case .accountHasNoSteamID:
            return "This account has no SteamID, so it cannot be saved."
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

    /// Decrypts and decodes every account in the manifest.
    public func loadAccounts(passphrase: String?) throws -> [SteamGuardAccount] {
        if manifest.encrypted, passphrase == nil || passphrase!.isEmpty {
            throw StoreError.passphraseRequired
        }

        var accounts = [SteamGuardAccount]()
        for entry in manifest.entries {
            let url = directory.appendingPathComponent(entry.filename)
            guard let data = try? Data(contentsOf: url) else {
                throw StoreError.accountFileMissing(entry.filename)
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
                throw CryptoError.wrongPassword
            }
            // Entries carry the SteamID even when the file predates sessions.
            if account.session == nil, entry.steamID != 0 {
                account.session = SessionData(steamID: entry.steamID)
            }
            accounts.append(account)
        }
        return accounts
    }

    /// Writes one account, encrypting it when the store is encrypted.
    public func save(_ account: SteamGuardAccount, passphrase: String?) throws {
        guard let steamID = account.session?.steamID, steamID != 0 else {
            throw StoreError.accountHasNoSteamID
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(account)
        let plaintext = String(decoding: json, as: UTF8.self)

        var entry = ManifestEntry(filename: "\(steamID).maFile", steamID: steamID)
        let contents: Data

        if manifest.encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw StoreError.passphraseRequired }
            // Fresh salt and IV on every write, so repeated saves never reuse a
            // keystream position with the same key.
            let salt = FileEncryptor.randomSalt()
            let iv = FileEncryptor.randomIV()
            let ciphertext = try FileEncryptor.encrypt(
                plaintext: plaintext,
                passphrase: passphrase,
                salt: salt,
                iv: iv
            )
            entry.salt = salt
            entry.iv = iv
            contents = Data(ciphertext.utf8)
        } else {
            contents = json
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(contents, to: directory.appendingPathComponent(entry.filename))

        if let index = manifest.entries.firstIndex(where: { $0.steamID == steamID }) {
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
    /// Accounts are decrypted into memory first so a failure part-way through
    /// cannot leave half the folder under one key and half under another.
    public func changeEncryption(currentPassphrase: String?, newPassphrase: String?) throws {
        let accounts = try loadAccounts(passphrase: currentPassphrase)

        let previousEncrypted = manifest.encrypted
        manifest.encrypted = (newPassphrase?.isEmpty == false)

        do {
            for account in accounts {
                try save(account, passphrase: newPassphrase)
            }
        } catch {
            manifest.encrypted = previousEncrypted
            try? saveManifest()
            throw error
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

    /// Imports a whole `maFiles` folder: reads its manifest for the per-file
    /// salts and IVs, then re-saves each account into this store.
    public func importFolder(
        at url: URL,
        sourcePassphrase: String?,
        storePassphrase: String?
    ) throws -> [SteamGuardAccount] {
        let sourceManifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: sourceManifestURL),
              let sourceManifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw StoreError.manifestUnreadable }

        var imported = [SteamGuardAccount]()
        for entry in sourceManifest.entries {
            let fileURL = url.appendingPathComponent(entry.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let account = try importMaFile(
                at: fileURL,
                sourcePassphrase: entry.isEncrypted ? sourcePassphrase : nil,
                sourceSalt: entry.salt,
                sourceIV: entry.iv,
                storePassphrase: storePassphrase
            )
            imported.append(account)
        }
        return imported
    }

    // MARK: - Disk

    /// Writes with an owner-only file mode: these files are the account.
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
