import Foundation
import Testing

@testable import SteamAuthKit

/// Reference values in this file were produced independently of the Swift code:
/// the code vector comes from steamguard-cli's own test suite, the PBKDF2 key
/// from Python's `hashlib.pbkdf2_hmac`, and the ciphertext from `openssl enc`.
/// They pin the on-disk and on-the-wire formats, which must stay compatible with
/// Steam Desktop Authenticator and with Steam itself.
struct CodeGenerationTests {

    private func account(sharedSecret: String) -> SteamGuardAccount {
        var account = SteamGuardAccount()
        account.sharedSecret = sharedSecret
        return account
    }

    @Test("Known Steam Guard code vector")
    func knownVector() {
        let account = self.account(sharedSecret: "zvIayp3JPvtvX/QGHqsqKBk/44s=")
        #expect(account.generateCode(forTime: 1_616_374_841) == "2F9J5")
    }

    @Test("Further code vectors")
    func moreVectors() {
        let account = self.account(sharedSecret: "zvIayp3JPvtvX/QGHqsqKBk/44s=")
        #expect(account.generateCode(forTime: 1_700_000_000) == "RB5CV")
        #expect(account.generateCode(forTime: 0) == "8J8QF")
    }

    @Test("Codes are stable across a 30-second window and change after it")
    func windowBehaviour() {
        let account = self.account(sharedSecret: "zvIayp3JPvtvX/QGHqsqKBk/44s=")
        // 1616374841 / 30 = 53879161, so the window covers 53879161*30 ..< +30.
        let windowStart: Int64 = 53_879_161 * 30
        let first = account.generateCode(forTime: windowStart)
        #expect(account.generateCode(forTime: windowStart + 29) == first)
        #expect(account.generateCode(forTime: windowStart + 30) != first)
    }

    @Test("Codes only use Steam's alphabet")
    func alphabet() {
        let account = self.account(sharedSecret: "zvIayp3JPvtvX/QGHqsqKBk/44s=")
        let allowed = Set("23456789BCDFGHJKMNPQRTVWXY")

        for step in 0 ..< 200 {
            let code = account.generateCode(forTime: Int64(step) * 31 + 1_600_000_000)
            let unwrapped = try! #require(code)
            #expect(unwrapped.count == 5)
            #expect(unwrapped.allSatisfy { allowed.contains($0) })
        }
    }

    @Test("A missing or malformed secret yields no code rather than a crash")
    func badSecrets() {
        #expect(SteamGuardAccount().generateCode(forTime: 1_616_374_841) == nil)
        #expect(account(sharedSecret: "").generateCode(forTime: 1_616_374_841) == nil)
        #expect(account(sharedSecret: "not base64 at all!!").generateCode(forTime: 1) == nil)
    }

    @Test("Escaped secrets in maFiles still decode")
    func escapedSecret() {
        // Some maFiles carry JSON-escaped forward slashes in the secret.
        let escaped = account(sharedSecret: "zvIayp3JPvtvX\\/QGHqsqKBk\\/44s=")
        #expect(escaped.generateCode(forTime: 1_616_374_841) == "2F9J5")
    }
}

struct ConfirmationSigningTests {
    private let identitySecret = "AqoNZ1QXm1uJMqiMcLxJ6RtJVXE="

    private var account: SteamGuardAccount {
        var account = SteamGuardAccount()
        account.identitySecret = identitySecret
        account.deviceID = "android:00000000-0000-0000-0000-000000000000"
        account.session = SessionData(steamID: 76_561_190_000_000_000)
        return account
    }

    @Test("Confirmation hashes match an independent HMAC-SHA1 implementation")
    func knownHashes() {
        #expect(
            account.confirmationHash(forTime: 1_616_374_841, tag: "list")
                == "W4e1zcFPKj6FGwYtO3VHak/kw6s="
        )
        #expect(
            account.confirmationHash(forTime: 1_616_374_841, tag: "accept")
                == "Cc+HvlmF3SGZdRZCLqxFGjdqcd0="
        )
    }

    @Test("Query items carry every parameter Steam requires")
    func queryItems() throws {
        let items = try account.confirmationQueryItems(forTime: 1_616_374_841, tag: "list")
        let names = Set(items.map(\.name))
        #expect(names == ["p", "a", "k", "t", "m", "tag"])
        #expect(items.first { $0.name == "m" }?.value == "react")
        #expect(items.first { $0.name == "t" }?.value == "1616374841")
    }

    @Test("Base64 signatures are percent-encoded in the query string")
    func plusSignEncoding() throws {
        // '+' is legal in base64 and means a space in a query string. Leaving it
        // unescaped silently breaks the signature, so it must be percent-encoded.
        let items = try account.confirmationQueryItems(forTime: 1_616_374_841, tag: "accept")
        let query = SteamWeb.queryString(items)
        #expect(query.contains("Cc%2BHvlmF3SGZdRZCLqxFGjdqcd0%3D"))
        #expect(!query.contains("Cc+Hvlm"))
    }

    @Test("Signing without a device ID is reported, not guessed at")
    func missingDeviceID() {
        var account = self.account
        account.deviceID = nil
        #expect(throws: SteamError.self) {
            try account.confirmationQueryItems(forTime: 1, tag: "list")
        }
    }
}

struct FileEncryptionTests {
    // An end-to-end SDA-format vector: PBKDF2 from Python, AES from OpenSSL.
    private let passphrase = "correct horse battery staple"
    private let salt = "AAECAwQFBgc="
    private let iv = "AAECAwQFBgcICQoLDA0ODw=="
    private let plaintext = #"{"shared_secret":"zvIayp3JPvtvX/QGHqsqKBk/44s="}"#
    private let ciphertext =
        "nHg7qhYQqUC7RO1Nfs1kxrcB9RGUcUMOkY1XcJsTn9MNTLd1fihJLlgadtbzQ0WEdJkkWYW5lcnUjMwpYbUIKw=="

    @Test("PBKDF2 derivation matches Python's hashlib")
    func pbkdf2Vector() throws {
        let key = try Crypto.pbkdf2SHA1(
            password: passphrase,
            salt: Data(base64Encoded: salt)!,
            rounds: FileEncryptor.pbkdf2Rounds,
            keyLength: 32
        )
        #expect(key.hexString == "4152035e8ad5fb67d1468323eb031b1a696658a8d6c0cc9928043acf40bc9e8a")
    }

    @Test("Encrypting reproduces the OpenSSL ciphertext")
    func encryptVector() throws {
        let encrypted = try FileEncryptor.encrypt(
            plaintext: plaintext,
            passphrase: passphrase,
            salt: salt,
            iv: iv
        )
        #expect(encrypted == ciphertext)
    }

    @Test("Decrypting an externally produced ciphertext works")
    func decryptVector() throws {
        let decrypted = try FileEncryptor.decrypt(
            ciphertext: ciphertext,
            passphrase: passphrase,
            salt: salt,
            iv: iv
        )
        #expect(decrypted == plaintext)
    }

    @Test("A wrong passphrase is rejected rather than returning garbage")
    func wrongPassphrase() {
        #expect(throws: CryptoError.self) {
            try FileEncryptor.decrypt(
                ciphertext: ciphertext,
                passphrase: "wrong passphrase",
                salt: salt,
                iv: iv
            )
        }
    }

    @Test("Round-trips survive a fresh random salt and IV")
    func randomRoundTrip() throws {
        let salt = FileEncryptor.randomSalt()
        let iv = FileEncryptor.randomIV()
        let secret = #"{"account_name":"example","shared_secret":"abc"}"#

        let encrypted = try FileEncryptor.encrypt(
            plaintext: secret, passphrase: "hunter2", salt: salt, iv: iv
        )
        let decrypted = try FileEncryptor.decrypt(
            ciphertext: encrypted, passphrase: "hunter2", salt: salt, iv: iv
        )
        #expect(decrypted == secret)
        #expect(Data(base64Encoded: salt)?.count == 8)
        #expect(Data(base64Encoded: iv)?.count == 16)
    }
}
