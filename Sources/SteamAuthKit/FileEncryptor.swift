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

    /// Decodes the stored base64, tolerating noise a copy may have added.
    ///
    /// `.ignoreUnknownCharacters` is what makes a byte order mark survivable:
    /// an maFile opened and resaved in a Windows editor gains one, every
    /// ciphertext byte intact, and strict decoding would write the account off
    /// as destroyed. The block-size check below is what still catches real
    /// rubbish, so being lenient here costs nothing.
    private static func decodeCiphertext(_ ciphertext: String) -> Data? {
        let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }

    /// Whether this is even shaped like something we wrote.
    ///
    /// A wrong passphrase never alters the file's bytes, so ciphertext that
    /// cannot be the output of this cipher is damaged no matter what
    /// passphrase is offered. That makes this the one check able to tell the
    /// two apart — but it has to be sure, because the interface treats damage
    /// as grounds for dropping the entry holding the file's only salt.
    public static func isWellFormed(ciphertext: String) -> Bool {
        guard let data = decodeCiphertext(ciphertext) else { return false }
        // AES-CBC output is whole blocks, and PKCS#7 means at least one.
        return data.count >= ivLength && data.count % ivLength == 0
    }

    public static func decrypt(
        ciphertext: String,
        passphrase: String,
        salt: String,
        iv: String
    ) throws -> String {
        guard let cipherData = decodeCiphertext(ciphertext) else { throw CryptoError.wrongPassword }
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
