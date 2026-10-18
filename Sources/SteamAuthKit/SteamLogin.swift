import Foundation

/// Steam's `IAuthenticationService` login flow.
///
/// SDA delegates this to SteamKit2, which is a .NET library and the main reason
/// SDA cannot be ported directly. The flow itself is only three calls, so it is
/// reimplemented here against the same protobuf service SteamKit2 talks to:
///
/// 1. fetch a per-attempt RSA key and encrypt the password with it,
/// 2. begin a session, which says which second factor is required,
/// 3. supply that factor, then poll until Steam hands over the tokens.
public enum SteamLogin {
    private static let interface = "IAuthenticationService"

    /// Matches the enum in `steammessages_auth.steamclient.proto`.
    public enum GuardType: Int, Sendable {
        case unknown = 0
        case none = 1
        case emailCode = 2
        case deviceCode = 3
        case deviceConfirmation = 4
        case emailConfirmation = 5
        case machineToken = 6
        case legacyMachineAuth = 7
    }

    private enum PlatformType: Int {
        case mobileApp = 3
    }

    /// `EOSType.AndroidUnknown`, so Steam treats this as the mobile app.
    private static let androidOSType: Int32 = -500

    public struct Challenge: Sendable {
        public var clientID: UInt64
        public var requestID: Data
        public var interval: TimeInterval
        public var steamID: UInt64
        public var allowedConfirmations: [(type: GuardType, message: String?)]

        /// The second factor Steam wants, preferring a code we might supply
        /// ourselves over a push to another device.
        public var requiredGuard: GuardType {
            let types = allowedConfirmations.map(\.type)
            for preferred: GuardType in [.deviceCode, .emailCode, .deviceConfirmation, .emailConfirmation] {
                if types.contains(preferred) { return preferred }
            }
            return types.first ?? .none
        }

        public var guardMessage: String? {
            allowedConfirmations.first { $0.type == requiredGuard }?.message
        }
    }

    public struct Credentials: Sendable {
        public var steamID: UInt64
        public var accountName: String?
        public var accessToken: String
        public var refreshToken: String
    }

    // MARK: - Step 1 & 2: begin a session

    public static func begin(
        accountName: String,
        password: String,
        deviceName: String = "Steam Desktop Authenticator for Mac"
    ) async throws -> Challenge {
        let rsa = try await passwordRSAPublicKey(accountName: accountName)

        let encrypted = try Crypto.rsaEncryptPKCS1(
            message: Data(password.utf8),
            modulusHex: rsa.modulus,
            exponentHex: rsa.exponent
        )

        var request = ProtoWriter()
        request.string(1, deviceName)
        request.string(2, accountName)
        request.string(3, encrypted.base64EncodedString())
        request.varint(4, rsa.timestamp)
        request.varint(6, PlatformType.mobileApp.rawValue)
        request.varint(7, 1) // ESessionPersistence.Persistent
        request.string(8, "Mobile")
        request.message(9) { details in
            details.string(1, deviceName)
            details.varint(2, PlatformType.mobileApp.rawValue)
            details.int32(3, androidOSType)
        }

        let response = try await SteamWeb.callService(
            interface: interface,
            method: "BeginAuthSessionViaCredentials",
            request: request
        )

        if let message = response.string(8), !message.isEmpty {
            throw SteamError.loginFailed(message)
        }

        guard let clientID = response.varint(1),
              let requestID = response.bytes(2)
        else {
            // Steam omits these when the credentials themselves were wrong.
            throw SteamError.loginFailed("Steam rejected that username or password.")
        }

        let confirmations = response.messages(4).map {
            (
                type: GuardType(rawValue: $0.int(1) ?? 0) ?? .unknown,
                message: $0.string(2)
            )
        }

        return Challenge(
            clientID: clientID,
            requestID: requestID,
            interval: TimeInterval(response.float(3) ?? 5),
            steamID: response.varint(5) ?? 0,
            allowedConfirmations: confirmations
        )
    }

    private static func passwordRSAPublicKey(
        accountName: String
    ) async throws -> (modulus: String, exponent: String, timestamp: UInt64) {
        var request = ProtoWriter()
        request.string(1, accountName)

        let response = try await SteamWeb.callService(
            interface: interface,
            method: "GetPasswordRSAPublicKey",
            request: request,
            httpMethod: "GET"
        )

        guard let modulus = response.string(1),
              let exponent = response.string(2),
              let timestamp = response.varint(3)
        else { throw SteamError.loginFailed("Steam did not return a login key for that account.") }

        return (modulus, exponent, timestamp)
    }

    // MARK: - Step 3: supply the second factor

    public static func submitGuardCode(
        challenge: Challenge,
        code: String,
        type: GuardType
    ) async throws {
        var request = ProtoWriter()
        request.varint(1, challenge.clientID)
        request.fixed64(2, challenge.steamID) // fixed64 here, unlike elsewhere
        request.string(3, code.trimmingCharacters(in: .whitespaces).uppercased())
        request.varint(4, type.rawValue)

        do {
            _ = try await SteamWeb.callService(
                interface: interface,
                method: "UpdateAuthSessionWithSteamGuardCode",
                request: request
            )
        } catch SteamError.apiError(let eresult, let message) {
            // 65 and 88 both mean "wrong code" depending on the guard type.
            if eresult == 65 || eresult == 88 {
                throw SteamError.loginFailed("That Steam Guard code was not accepted.")
            }
            throw SteamError.apiError(eresult: eresult, message: message)
        }
    }

    // MARK: - Step 4: poll for tokens

    /// One poll. Returns nil while Steam is still waiting for confirmation.
    public static func poll(challenge: Challenge) async throws -> Credentials? {
        var request = ProtoWriter()
        request.varint(1, challenge.clientID)
        request.bytes(2, challenge.requestID)

        let response = try await SteamWeb.callService(
            interface: interface,
            method: "PollAuthSessionStatus",
            request: request
        )

        guard let refreshToken = response.string(3), !refreshToken.isEmpty else { return nil }

        return Credentials(
            steamID: challenge.steamID,
            accountName: response.string(6),
            accessToken: response.string(4) ?? "",
            refreshToken: refreshToken
        )
    }

    /// Polls until Steam confirms the login or `timeout` elapses.
    ///
    /// Used for the push-to-device factors, where there is nothing to type and
    /// the user approves on their phone instead.
    public static func pollUntilConfirmed(
        challenge: Challenge,
        timeout: TimeInterval = 180
    ) async throws -> Credentials {
        let deadline = Date().addingTimeInterval(timeout)
        let interval = max(challenge.interval, 2)

        while Date() < deadline {
            if let credentials = try await poll(challenge: challenge) {
                return credentials
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw SteamError.loginFailed("Timed out waiting for the login to be approved.")
    }

    // MARK: - Token refresh

    /// Exchanges the long-lived refresh token for a fresh access token.
    ///
    /// Access tokens last about 24 hours, so this runs whenever a saved session
    /// is reloaded. `allowRenewal` also rotates the refresh token, which must
    /// then be written back to the maFile or the session is lost.
    public static func refreshAccessToken(
        session: SessionData,
        allowRenewal: Bool = false
    ) async throws -> SessionData {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw SteamError.noSession
        }
        guard !session.isRefreshTokenExpired else { throw SteamError.needsAuthentication }

        var request = ProtoWriter()
        request.string(1, refreshToken)
        request.fixed64(2, session.steamID)
        request.varint(3, allowRenewal ? 1 : 0)

        let response = try await SteamWeb.callService(
            interface: interface,
            method: "GenerateAccessTokenForApp",
            request: request
        )

        guard let accessToken = response.string(1), !accessToken.isEmpty else {
            throw SteamError.needsAuthentication
        }

        var updated = session
        updated.accessToken = accessToken
        if let rotated = response.string(2), !rotated.isEmpty {
            updated.refreshToken = rotated
        }
        return updated
    }
}
