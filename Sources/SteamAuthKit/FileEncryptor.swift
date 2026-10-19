import Foundation

/// maFile encryption, byte-compatible with Steam Desktop Authenticator.
///
/// An encrypted maFile is the base64 of AES-256-CBC(PKCS#7) over the account
/// JSON. The key comes from PBKDF2-SHA1 of the passphrase, and the salt and IV
/// live in `manifest.json` beside the file rather than in the file itself.
///
/// The parameters below are fixed by that format. 50,000 PBKDF2 rounds is low by
/// modern standards, but raising it would make files unreadable by SDA, which
/// defeats the point of being compatible.
public enum FileEncryptor {
    public static let pbkdf2Rounds = 50_000
    public static let saltLength = 8
    public static let keyLength = 32
    public static let ivLength = 16

    public static func randomSalt() -> String {
        Crypto.randomBytes(saltLength).base64EncodedString()
    }

    public static func randomIV() -> String {
        Crypto.randomBytes(ivLength).base64EncodedString()
    }

    private static func key(passphrase: String, salt: String) throws -> Data {
        guard !passphrase.isEmpty else { throw CryptoError.wrongPassword }
        guard let saltData = Data(base64Encoded: salt) else { throw CryptoError.keyDerivationFailed }
        return try Crypto.pbkdf2SHA1(
            password: passphrase,
            salt: saltData,
            rounds: pbkdf2Rounds,
            keyLength: keyLength
        )
    }

    public static func encrypt(
        plaintext: String,
        passphrase: String,
        salt: String,
        iv: String
    ) throws -> String {
        guard let ivData = Data(base64Encoded: iv) else { throw CryptoError.badIVSize }
        let derivedKey = try key(passphrase: passphrase, salt: salt)
        let ciphertext = try Crypto.aes256CBC(
            .encrypt,
            key: derivedKey,
            iv: ivData,
            data: Data(plaintext.utf8)
        )
        return ciphertext.base64EncodedString()
    }

    /// Whether this is even shaped like something we wrote.
    ///
    /// A wrong passphrase never alters the file's bytes, so ciphertext that is
    /// not valid base64 is damaged no matter what passphrase is offered. That
    /// makes this the one check that can tell the two apart.
    public static func isWellFormed(ciphertext: String) -> Bool {
        let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = Data(base64Encoded: trimmed) else { return false }
        // AES-CBC output is whole blocks, and PKCS#7 means at least one.
        return data.count >= ivLength && data.count % ivLength == 0
    }

    public static func decrypt(
        ciphertext: String,
        passphrase: String,
        salt: String,
        iv: String
    ) throws -> String {
        let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cipherData = Data(base64Encoded: trimmed) else { throw CryptoError.wrongPassword }
        guard let ivData = Data(base64Encoded: iv) else { throw CryptoError.badIVSize }

        let derivedKey = try key(passphrase: passphrase, salt: salt)
        let plaintext = try Crypto.aes256CBC(
            .decrypt,
            key: derivedKey,
            iv: ivData,
            data: cipherData
        )

        guard let text = String(data: plaintext, encoding: .utf8) else {
            // Unpadding succeeded but the result is not text: wrong passphrase.
            throw CryptoError.wrongPassword
        }
        return text
    }
}
