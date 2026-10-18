import Foundation

/// A single Steam account's authenticator secrets: the contents of one `.maFile`.
///
/// The coding keys mirror Steam Desktop Authenticator's on-disk format exactly,
/// so maFiles copied from a Windows install load here and files written here load
/// back in SDA. Note the capitalised `Session` key: SDA serialises that object
/// with .NET property names rather than snake_case.
public struct SteamGuardAccount: Codable, Identifiable, Hashable, Sendable {
    public var sharedSecret: String?
    public var serialNumber: String?
    public var revocationCode: String?
    public var uri: String?
    public var serverTime: Int64?
    public var accountName: String?
    public var tokenGID: String?
    public var identitySecret: String?
    public var secret1: String?
    public var status: Int?
    public var deviceID: String?
    public var phoneNumberHint: String?
    public var confirmType: Int?
    public var fullyEnrolled: Bool?
    public var session: SessionData?

    /// Stable across reads: a computed UUID fallback would hand out a different
    /// identity every time, breaking list selection and id-keyed lookups.
    public var id: String {
        if let accountName, !accountName.isEmpty { return accountName }
        if let tokenGID, !tokenGID.isEmpty { return tokenGID }
        if let steamID = session?.steamID, steamID != 0 { return String(steamID) }
        return "unknown-account"
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sharedSecret = "shared_secret"
        case serialNumber = "serial_number"
        case revocationCode = "revocation_code"
        case uri
        case serverTime = "server_time"
        case accountName = "account_name"
        case tokenGID = "token_gid"
        case identitySecret = "identity_secret"
        case secret1 = "secret_1"
        case status
        case deviceID = "device_id"
        case phoneNumberHint = "phone_number_hint"
        case confirmType = "confirm_type"
        case fullyEnrolled = "fully_enrolled"
        case session = "Session"
    }

    /// Decoded leniently: the same fields arrive as numbers from maFiles and as
    /// quoted strings from `ITwoFactorService/AddAuthenticator`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedSecret = container.lenientString(.sharedSecret)
        serialNumber = container.lenientString(.serialNumber)
        revocationCode = container.lenientString(.revocationCode)
        uri = container.lenientString(.uri)
        serverTime = container.lenientInt64(.serverTime)
        accountName = container.lenientString(.accountName)
        tokenGID = container.lenientString(.tokenGID)
        identitySecret = container.lenientString(.identitySecret)
        secret1 = container.lenientString(.secret1)
        status = container.lenientInt(.status)
        deviceID = container.lenientString(.deviceID)
        phoneNumberHint = container.lenientString(.phoneNumberHint)
        confirmType = container.lenientInt(.confirmType)
        fullyEnrolled = container.lenientBool(.fullyEnrolled)
        session = try? container.decodeIfPresent(SessionData.self, forKey: .session)
    }

    // MARK: - Code generation

    /// Steam encodes codes in this 26-character alphabet rather than base 10.
    private static let codeAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY".utf8)

    /// Generates the five-character Steam Guard code for a given Steam time.
    ///
    /// This is RFC 4226 HOTP with a 30-second step, except the dynamically
    /// truncated value is rendered in base 26 instead of base 10.
    public func generateCode(forTime time: Int64) -> String? {
        guard let sharedSecret, !sharedSecret.isEmpty,
              let key = Data(base64Encoded: sharedSecret.unescapedJSONString)
        else { return nil }

        var counter = UInt64(max(0, time) / 30)
        var message = Data(count: 8)
        for index in (0 ..< 8).reversed() {
            message[index] = UInt8(counter & 0xFF)
            counter >>= 8
        }

        let hash = Crypto.hmacSHA1(key: key, message: message)
        guard hash.count == 20 else { return nil }

        let offset = Int(hash[19] & 0x0F)
        var codePoint =
            (UInt32(hash[offset] & 0x7F) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])

        var characters = [UInt8]()
        for _ in 0 ..< 5 {
            let alphabetCount = UInt32(Self.codeAlphabet.count)
            characters.append(Self.codeAlphabet[Int(codePoint % alphabetCount)])
            codePoint /= alphabetCount
        }
        return String(decoding: characters)
    }

    public func generateCode() async -> String? {
        generateCode(forTime: await SteamTime.shared.currentTime())
    }

    // MARK: - Confirmation signing

    /// Mobile confirmation requests are signed with `identity_secret` over the
    /// current time plus a per-operation tag.
    func confirmationHash(forTime time: Int64, tag: String) -> String? {
        guard let identitySecret, let key = Data(base64Encoded: identitySecret) else { return nil }

        let tagBytes = Data(tag.utf8.prefix(32))
        var message = Data(count: 8)
        var counter = UInt64(max(0, time))
        for index in (0 ..< 8).reversed() {
            message[index] = UInt8(counter & 0xFF)
            counter >>= 8
        }
        message.append(tagBytes)

        return Crypto.hmacSHA1(key: key, message: message).base64EncodedString()
    }

    /// Query items shared by every `/mobileconf/` endpoint.
    func confirmationQueryItems(forTime time: Int64, tag: String) throws -> [URLQueryItem] {
        guard let deviceID, !deviceID.isEmpty else { throw SteamError.missingDeviceID }
        guard let session else { throw SteamError.noSession }
        guard let hash = confirmationHash(forTime: time, tag: tag) else {
            throw SteamError.missingIdentitySecret
        }

        return [
            URLQueryItem(name: "p", value: deviceID),
            URLQueryItem(name: "a", value: String(session.steamID)),
            URLQueryItem(name: "k", value: hash),
            URLQueryItem(name: "t", value: String(time)),
            URLQueryItem(name: "m", value: "react"),
            URLQueryItem(name: "tag", value: tag),
        ]
    }

    /// Steam derives device IDs from the SteamID in the mobile app; SDA generates a
    /// random one instead and Steam accepts it, as long as it stays stable.
    public static func generateDeviceID() -> String {
        "android:\(UUID().uuidString.lowercased())"
    }
}

// MARK: - Session

/// Steam web session: a long-lived refresh token plus a short-lived access token.
///
/// Keys are capitalised to match what SDA's .NET serialiser writes into maFiles.
public struct SessionData: Codable, Hashable, Sendable {
    public var steamID: UInt64 = 0
    public var accessToken: String?
    public var refreshToken: String?
    public var sessionID: String?

    public init(steamID: UInt64 = 0, accessToken: String? = nil, refreshToken: String? = nil, sessionID: String? = nil) {
        self.steamID = steamID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        // Settled once, here, so it is stable across requests and gets persisted
        // with the account rather than regenerated on every call.
        self.sessionID = sessionID ?? Self.generateSessionID()
    }

    enum CodingKeys: String, CodingKey {
        case steamID = "SteamID"
        case accessToken = "AccessToken"
        case refreshToken = "RefreshToken"
        case sessionID = "SessionID"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Older maFiles wrote SteamID as a string; current ones use a number.
        if let value = try? container.decode(UInt64.self, forKey: .steamID) {
            steamID = value
        } else if let text = try? container.decode(String.self, forKey: .steamID) {
            steamID = UInt64(text) ?? 0
        }
        accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try? container.decodeIfPresent(String.self, forKey: .refreshToken)
        sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID))
            ?? Self.generateSessionID()
    }

    // MARK: Token expiry

    /// Steam's tokens are JWTs; the `exp` claim tells us when to refresh.
    private func expiry(of token: String?) -> Int64? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if base64.count % 4 != 0 {
            base64 += String(repeating: "=", count: 4 - base64.count % 4)
        }

        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber
        else { return nil }
        return exp.int64Value
    }

    private func isExpired(_ token: String?, within seconds: Int64 = 0) -> Bool {
        guard let expiry = expiry(of: token) else { return true }
        return Int64(Date().timeIntervalSince1970) + seconds > expiry
    }

    public var isAccessTokenExpired: Bool {
        guard let accessToken, !accessToken.isEmpty else { return true }
        return isExpired(accessToken)
    }

    public var isRefreshTokenExpired: Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return true }
        return isExpired(refreshToken)
    }

    /// True within 24 hours of expiry, which is when SDA prompts for a re-login.
    public var isRefreshTokenAboutToExpire: Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return true }
        return isExpired(refreshToken, within: 24 * 60 * 60)
    }

    /// Cookies the `/mobileconf/` pages expect. `steamLoginSecure` carries the
    /// access token; the `mobileClient` pair makes Steam serve the mobile flow.
    public func cookieHeader() -> String {
        let loginSecure = "\(steamID)%7C%7C\(accessToken ?? "")"
        return [
            "steamLoginSecure=\(loginSecure)",
            "sessionid=\(sessionID ?? Self.generateSessionID())",
            "mobileClient=android",
            "mobileClientVersion=777777 3.6.4",
        ].joined(separator: "; ")
    }

    static func generateSessionID() -> String {
        Crypto.randomBytes(16).hexString.uppercased()
    }
}

// MARK: - Helpers

extension String {
    /// maFiles occasionally contain JSON-escaped secrets (`a\/b`), which .NET's
    /// `Regex.Unescape` strips before base64 decoding. Mirror that.
    var unescapedJSONString: String {
        replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

extension String {
    init(decoding bytes: [UInt8]) {
        self = String(decoding: bytes, as: UTF8.self)
    }
}
