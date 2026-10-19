import Foundation
import LocalAuthentication
import Security

/// Optional storage for the maFiles passphrase in the login keychain.
///
/// SDA takes the passphrase on the command line (`-k`), which leaves it in shell
/// history and the process list. The keychain is the equivalent on macOS, and it
/// can additionally be gated behind Touch ID.
enum Keychain {
    private static let service = "com.sdamac.SDA.passphrase"
    private static let account = "maFiles"
    private static let protectionKey = "passphraseProtection"

    /// How the stored passphrase is guarded.
    enum Protection: String {
        /// Readable whenever the login keychain is unlocked.
        case plain
        /// Requires Touch ID, or the login password as fallback.
        case biometric
    }

    enum KeychainError: LocalizedError {
        case notFound
        case authenticationFailed
        /// The user dismissed the prompt themselves. Its cancel button offers
        /// the passphrase, so the caller is expected to show that instead.
        case declined
        /// Something other than the user took the prompt away, so re-offering
        /// it is the right response rather than falling back.
        case interrupted
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No passphrase is saved on this Mac."
            case .authenticationFailed:
                return "\(biometryLabel) did not confirm it was you."
            case .declined, .interrupted:
                return nil // Not a failure worth reporting.
            case .unavailable(let detail):
                return detail
            }
        }
    }

    // MARK: - Biometry

    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    /// What to call it in the interface, since the hardware differs by Mac.
    static var biometryLabel: String {
        switch LAContext().biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "biometrics"
        }
    }

    // MARK: - State

    static var hasStoredPassphrase: Bool {
        // Attributes only: this does not decrypt the item, so it never prompts.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static var storedProtection: Protection? {
        guard hasStoredPassphrase else { return nil }
        let raw = UserDefaults.standard.string(forKey: protectionKey) ?? Protection.plain.rawValue
        return Protection(rawValue: raw) ?? .plain
    }

    // MARK: - Writing

    @discardableResult
    static func save(passphrase: String, protection: Protection) -> Bool {
        // Updating in place keeps the existing item if the write fails, rather
        // than deleting it first and leaving nothing behind.
        if storedProtection == protection, hasStoredPassphrase {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            let changes: [CFString: Any] = [kSecValueData: Data(passphrase.utf8)]

            if SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess {
                UserDefaults.standard.set(protection.rawValue, forKey: protectionKey)
                return true
            }
        }

        delete()

        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(passphrase.utf8),
        ]

        if protection == .biometric {
            // .userPresence means Touch ID with the login password as fallback,
            // and unlike .biometryCurrentSet it survives adding a fingerprint.
            var error: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) {
                attributes[kSecAttrAccessControl] = access
            } else {
                // Without an ACL the item is still gated by the check in load().
                attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        } else {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        }

        var status = SecItemAdd(attributes as CFDictionary, nil)

        // Some Macs refuse an access-control item for an app without a
        // provisioning profile; fall back rather than losing the passphrase.
        if status != errSecSuccess, protection == .biometric {
            attributes.removeValue(forKey: kSecAttrAccessControl)
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }

        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(protection.rawValue, forKey: protectionKey)
        return true
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: protectionKey)
        return status == errSecSuccess
    }

    // MARK: - Reading

    /// Reads the passphrase, asking for Touch ID first when it is protected.
    ///
    /// The authenticated context is handed to the keychain so an access-control
    /// item does not ask a second time.
    static func load(reason: String) async -> Result<String, KeychainError> {
        guard hasStoredPassphrase else { return .failure(.notFound) }

        var context: LAContext?

        if storedProtection == .biometric {
            let authContext = LAContext()
            authContext.localizedCancelTitle = "Enter Passphrase"

            do {
                // .deviceOwnerAuthentication allows the login password as a
                // fallback, so a wet finger is not a lockout.
                let ok = try await authContext.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
                guard ok else { return .failure(.authenticationFailed) }
                context = authContext
            } catch let error as LAError {
                switch error.code {
                case .userCancel, .userFallback:
                    // The cancel button is labelled "Enter Passphrase", so
                    // dismissing the prompt is a request for the other route.
                    return .failure(.declined)
                case .appCancel, .systemCancel:
                    return .failure(.interrupted)
                case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                    return .failure(.unavailable(
                        "\(biometryLabel) is not set up on this Mac. Enter your passphrase instead."
                    ))
                default:
                    return .failure(.authenticationFailed)
                }
            } catch {
                return .failure(.authenticationFailed)
            }
        }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let context { query[kSecUseAuthenticationContext] = context }

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let passphrase = String(data: data, encoding: .utf8)
        else { return .failure(.notFound) }

        return .success(passphrase)
    }

    /// Reads without any prompt. Returns nil when the item is Touch ID protected.
    static func loadUnprotected() -> String? {
        guard storedProtection == .plain else { return nil }

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
}
