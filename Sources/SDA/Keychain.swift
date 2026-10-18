import Foundation
import Security

/// Optional storage for the maFiles passphrase in the login keychain.
///
/// SDA takes the passphrase on the command line (`-k`), which leaves it in shell
/// history and the process list. The keychain is the equivalent on macOS: the
/// passphrase is protected by the login password and never written beside the
/// encrypted files it unlocks.
enum Keychain {
    private static let service = "com.sdamac.SDA.passphrase"
    private static let account = "maFiles"

    static func save(passphrase: String) -> Bool {
        delete()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(passphrase.utf8),
            // Needs an unlocked keychain, and never syncs to iCloud.
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static var hasStoredPassphrase: Bool { load() != nil }
}
