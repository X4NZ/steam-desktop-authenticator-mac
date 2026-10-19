import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Low-level primitives, kept byte-compatible with Steam Desktop Authenticator
/// and with Steam's mobile app so existing maFiles and sessions keep working.
public enum Crypto {

    // MARK: - HMAC-SHA1

    /// Steam signs both TOTP codes and mobile confirmation requests with HMAC-SHA1.
    public static func hmacSHA1(key: Data, message: Data) -> Data {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(mac)
    }

    // MARK: - PBKDF2

    /// SDA derives maFile keys with 50k rounds of PBKDF2-SHA1. The round count is
    /// part of the on-disk format, so it cannot be raised without breaking
    /// compatibility with maFiles written by SDA itself.
    public static func pbkdf2SHA1(
        password: String,
        salt: Data,
        rounds: Int,
        keyLength: Int
    ) throws -> Data {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)

        // Both pointers are used strictly inside the closures that own them:
        // returning baseAddress out of withUnsafeBufferPointer would leave the
        // pointer's lifetime undefined.
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(rounds),
                    &derived,
                    keyLength
                )
            }
        }

        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return Data(derived)
    }

    // MARK: - AES-256-CBC

    public enum AESOperation {
        case encrypt
        case decrypt

        var ccValue: CCOperation {
            switch self {
            case .encrypt: return CCOperation(kCCEncrypt)
            case .decrypt: return CCOperation(kCCDecrypt)
            }
        }
    }

    /// AES-256 in CBC mode with PKCS#7 padding, matching SDA's RijndaelManaged usage.
    public static func aes256CBC(_ operation: AESOperation, key: Data, iv: Data, data: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else { throw CryptoError.badKeySize }
        guard iv.count == kCCBlockSizeAES128 else { throw CryptoError.badIVSize }

        // Padding can add up to one extra block on the way out.
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var movedBytes = 0

        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                data.withUnsafeBytes { dataBuffer in
                    CCCrypt(
                        operation.ccValue,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress, key.count,
                        ivBuffer.baseAddress,
                        dataBuffer.baseAddress, data.count,
                        &output, output.count,
                        &movedBytes
                    )
                }
            }
        }

        switch Int(status) {
        case kCCSuccess:
            return Data(output.prefix(movedBytes))
        case kCCDecodeError, kCCAlignmentError:
            // Almost always a wrong passphrase: the derived key fails to unpad.
            throw CryptoError.wrongPassword
        default:
            throw CryptoError.cipherFailed(Int(status))
        }
    }

    // MARK: - RSA

    /// Encrypts a password with the RSA public key Steam hands out per login attempt.
    /// Steam returns the modulus and exponent as hex strings and expects
    /// PKCS#1 v1.5 ciphertext, base64 encoded.
    public static func rsaEncryptPKCS1(
        message: Data,
        modulusHex: String,
        exponentHex: String
    ) throws -> Data {
        guard let modulus = Data(hexString: modulusHex),
              let exponent = Data(hexString: exponentHex)
        else { throw CryptoError.badRSAKey }

        let keyData = DER.rsaPublicKey(modulus: modulus, exponent: exponent)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw CryptoError.badRSAKey
        }

        guard let ciphertext = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionPKCS1,
            message as CFData,
            &error
        ) else {
            throw CryptoError.rsaEncryptionFailed
        }

        return ciphertext as Data
    }

    // MARK: - Random

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // Ignoring this would hand back a buffer of zeroes, and these bytes
        // become encryption salts and IVs. Predictable ones are worse than
        // stopping, and the system RNG failing is not a recoverable state.
        precondition(status == errSecSuccess, "the system random number generator failed")
        return Data(bytes)
    }
}

public enum CryptoError: LocalizedError {
    case keyDerivationFailed
    case badKeySize
    case badIVSize
    case wrongPassword
    case cipherFailed(Int)
    case badRSAKey
    case rsaEncryptionFailed

    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: return "Could not derive a key from that passphrase."
        case .badKeySize: return "Internal error: wrong AES key size."
        case .badIVSize: return "Internal error: wrong AES initialization vector size."
        case .wrongPassword: return "Incorrect passphrase."
        case .cipherFailed(let code): return "Encryption failed (code \(code))."
        case .badRSAKey: return "Steam returned an RSA key that could not be parsed."
        case .rsaEncryptionFailed: return "Could not encrypt the password for Steam."
        }
    }
}

// MARK: - Minimal DER writer for RSA public keys

enum DER {
    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        sequence(integer(modulus) + integer(exponent))
    }

    private static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        // DER integers are signed, so a leading high bit needs a zero pad.
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tagged(0x02, bytes)
    }

    private static func sequence(_ body: Data) -> Data {
        tagged(0x30, body)
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        out.append(length(body.count))
        out.append(body)
        return out
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }

        var lengthBytes = Data()
        var remaining = count
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(lengthBytes.count)]) + lengthBytes
    }
}

// MARK: - Hex

extension Data {
    public init?(hexString: String) {
        let characters = Array(hexString)
        guard characters.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)

        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
