import Foundation

/// Moves an authenticator onto this machine, and off it again.
///
/// The sequence Steam enforces is: the account must have a verified phone
/// number, then `AddAuthenticator` returns the secrets, then an SMS code proves
/// the phone is in hand and finalizes the link. Nothing is a real authenticator
/// until finalization succeeds — but the secrets arrive before it, which is why
/// they must be saved to disk the moment they are received.
public final class AuthenticatorLinker {
    public private(set) var session: SessionData
    public private(set) var deviceID: String

    /// Populated by `addAuthenticator`. Save this immediately: losing it after
    /// finalization means losing access to the account.
    public private(set) var linkedAccount: SteamGuardAccount?

    /// Where the phone-verification email was sent, when Steam sends one.
    public private(set) var confirmationEmailAddress: String?

    public init(session: SessionData, deviceID: String = SteamGuardAccount.generateDeviceID()) {
        self.session = session
        self.deviceID = deviceID
    }

    private var accessToken: String {
        get throws {
            guard let token = session.accessToken, !token.isEmpty else {
                throw SteamError.needsAuthentication
            }
            return token
        }
    }

    // MARK: - Phone number

    public enum PhoneStep: Equatable, Sendable {
        /// A verified phone is already on the account; go straight to linking.
        case ready
        /// No phone on the account and none supplied yet.
        case needsPhoneNumber
        /// Steam emailed a confirmation link that must be clicked first.
        case needsEmailConfirmation(address: String?)
        /// An SMS was sent; Steam wants the code from it.
        case needsSMSCode
    }

    public func phoneStatus() async throws -> (hasPhone: Bool, verified: Bool) {
        let data = try await post("\(SteamEndpoints.api)/IPhoneService/AccountPhoneStatus/v1")
        let response = try json(data)
        return (
            hasPhone: (response["has_phone"] as? Bool) ?? false,
            verified: (response["verified_phone"] as? Bool) ?? false
        )
    }

    /// Looks up the account's country so the phone number gets the right code.
    public func userCountry() async throws -> String? {
        let data = try await post(
            "\(SteamEndpoints.api)/IUserAccountService/GetUserCountry/v1",
            body: [URLQueryItem(name: "steamid", value: String(session.steamID))]
        )
        return try json(data)["country"] as? String
    }

    /// Attaches a phone number to the account.
    ///
    /// Steam answers with an email confirmation step; once the user has clicked
    /// that link, call `continueAfterEmailConfirmation()`.
    public func addPhoneNumber(_ phoneNumber: String, countryCode: String? = nil) async throws -> PhoneStep {
        let status = try await phoneStatus()
        if status.verified { return .ready }

        let normalized = Self.normalizePhoneNumber(phoneNumber)
        guard Self.isPlausiblePhoneNumber(normalized) else {
            throw SteamError.loginFailed(
                "Enter the phone number in international format, starting with + and the country code."
            )
        }

        // `??` takes a non-async autoclosure, so resolve the fallback separately.
        var country = countryCode
        if country == nil { country = try? await userCountry() }
        let data = try await post(
            "\(SteamEndpoints.api)/IPhoneService/SetAccountPhoneNumber/v1",
            body: [
                URLQueryItem(name: "phone_number", value: normalized),
                URLQueryItem(name: "phone_country_code", value: country ?? ""),
            ]
        )

        let response = try json(data)
        confirmationEmailAddress = response["confirmation_email_address"] as? String
        return .needsEmailConfirmation(address: confirmationEmailAddress)
    }

    public func isWaitingForEmailConfirmation() async throws -> Bool {
        let data = try await post(
            "\(SteamEndpoints.api)/IPhoneService/IsAccountWaitingForEmailConfirmation/v1"
        )
        return (try json(data)["awaiting_email_confirmation"] as? Bool) ?? false
    }

    /// Called once the user has clicked Steam's email link: sends the SMS.
    public func continueAfterEmailConfirmation() async throws -> PhoneStep {
        if try await isWaitingForEmailConfirmation() {
            return .needsEmailConfirmation(address: confirmationEmailAddress)
        }
        try await sendPhoneVerificationCode()
        // Steam needs a moment before the SMS is actually dispatched.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return .needsSMSCode
    }

    public func sendPhoneVerificationCode() async throws {
        _ = try await post("\(SteamEndpoints.api)/IPhoneService/SendPhoneVerificationCode/v1")
    }

    public func verifyPhone(code: String) async throws -> PhoneStep {
        _ = try await post(
            "\(SteamEndpoints.api)/IPhoneService/VerifyAccountPhoneWithCode/v1/",
            body: [URLQueryItem(name: "code", value: code.trimmingCharacters(in: .whitespaces))]
        )

        // This used to return .ready unconditionally, so a wrong code walked
        // on into addAuthenticator and failed there with something unrelated.
        // The account's own phone status is the answer that cannot be faked by
        // a 200 with an empty body.
        // A failure of this check is not the same as the code being wrong: the
        // verification may well have gone through, and the code is single use,
        // so reporting rejection would strand the user with a verified phone
        // and a code they cannot send again. Only a definite "still
        // unverified" counts as a rejection.
        // Retried once: a single dropped request is common enough that giving
        // up on it immediately would report every blip as a verified phone,
        // which is most of the way back to the bug this replaced.
        var status = try? await phoneStatus()
        if status == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            status = try? await phoneStatus()
        }
        guard let status else { return .ready }
        guard status.verified else {
            throw SteamError.loginFailed(
                "Steam did not accept that code. Check the SMS and try again."
            )
        }
        return .ready
    }

    // MARK: - Adding the authenticator

    public enum LinkResult: Equatable, Sendable {
        /// Secrets received and saved; an SMS code is needed to finalize.
        case awaitingFinalization(revocationCode: String?)
        case needsPhoneNumber
        case authenticatorAlreadyPresent
    }

    /// Requests the authenticator secrets from Steam.
    ///
    /// On success `linkedAccount` holds the shared and identity secrets plus the
    /// revocation code. Persist it before calling `finalize`.
    public func addAuthenticator() async throws -> LinkResult {
        let data = try await post(
            "\(SteamEndpoints.api)/ITwoFactorService/AddAuthenticator/v1/",
            body: [
                URLQueryItem(name: "steamid", value: String(session.steamID)),
                URLQueryItem(name: "authenticator_type", value: "1"),
                URLQueryItem(name: "device_identifier", value: deviceID),
                URLQueryItem(name: "sms_phone_id", value: "1"),
                URLQueryItem(name: "version", value: "2"),
            ]
        )

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseObject = root["response"]
        else { throw SteamError.badResponse }

        let response = (responseObject as? [String: Any]) ?? [:]
        let status = (response["status"] as? NSNumber)?.intValue
            ?? Int((response["status"] as? String) ?? "") ?? 0

        switch status {
        case 1:
            break
        case 2:
            return .needsPhoneNumber
        case 29:
            return .authenticatorAlreadyPresent
        default:
            throw SteamError.apiError(eresult: status, message: "Steam would not add an authenticator")
        }

        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        var account = try JSONDecoder().decode(SteamGuardAccount.self, from: responseData)
        account.deviceID = deviceID
        account.session = session
        account.fullyEnrolled = false
        linkedAccount = account

        return .awaitingFinalization(revocationCode: account.revocationCode)
    }

    public enum FinalizeResult: Equatable, Sendable {
        case success
        case badSMSCode
        /// Steam kept rejecting our codes, which means the clock is too far off.
        case unableToGenerateCorrectCodes
        /// Steam kept asking for another code until we ran out of patience.
        /// Distinct from the above: nothing was rejected, so the clock is fine.
        case steamKeptAskingForCodes
    }

    /// Completes the link using the SMS code Steam sent.
    ///
    /// Steam asks for repeated codes from successive time windows to prove the
    /// authenticator really works, hence the loop.
    public func finalize(smsCode: String) async throws -> FinalizeResult {
        guard let account = linkedAccount else { throw SteamError.badResponse }
        let code = smsCode.trimmingCharacters(in: .whitespaces)

        // Waiting for a fresh code window is right, but ten of them is up to
        // five minutes behind a bare spinner. Three windows is enough for the
        // couple of codes Steam actually asks for.
        let deadline = Date().addingTimeInterval(90)

        for attempt in 0 ..< 10 {
            let time = await SteamTime.shared.currentTime()
            guard let authenticatorCode = account.generateCode(forTime: time) else {
                return .unableToGenerateCorrectCodes
            }

            let data = try await post(
                "\(SteamEndpoints.api)/ITwoFactorService/FinalizeAddAuthenticator/v1/",
                body: [
                    URLQueryItem(name: "steamid", value: String(session.steamID)),
                    URLQueryItem(name: "authenticator_code", value: authenticatorCode),
                    URLQueryItem(name: "authenticator_time", value: String(time)),
                    URLQueryItem(name: "activation_code", value: code),
                    URLQueryItem(name: "validate_sms_code", value: "1"),
                ]
            )

            let response = try json(data)
            let status = (response["status"] as? NSNumber)?.intValue ?? 0
            let success = (response["success"] as? Bool) ?? false
            let wantMore = (response["want_more"] as? Bool) ?? false

            if status == 89 { return .badSMSCode }

            if status == 88 {
                // A code mismatch. Retrying inside the same 30-second window
                // regenerates the identical code, so the old immediate retry
                // burned all ten attempts on one code that Steam had already
                // refused. Give it a couple of fresh windows, and past that the
                // clock really is wrong.
                guard attempt < 2, Date() < deadline else {
                    return .unableToGenerateCorrectCodes
                }
                try await waitForNextCodeWindow()
                continue
            }

            if wantMore {
                // Same reasoning: a flat two-second sleep usually stayed inside
                // the current window and sent Steam the same code again.
                guard Date() < deadline else { return .steamKeptAskingForCodes }
                try await waitForNextCodeWindow()
                continue
            }
            if success {
                linkedAccount?.fullyEnrolled = true
                return .success
            }
        }
        return .unableToGenerateCorrectCodes
    }

    /// Sleeps until the current 30-second code window has rolled over, so the
    /// next generated code is genuinely a different one.
    private func waitForNextCodeWindow() async throws {
        let remaining = await SteamTime.shared.secondsRemaining()
        try await Task.sleep(nanoseconds: UInt64(max(1, remaining)) * 1_000_000_000)
    }

    // MARK: - Removal

    /// Removes the authenticator from the Steam account.
    ///
    /// `scheme` 1 returns the account to email codes; 2 removes Steam Guard
    /// entirely. This needs the revocation code and cannot be undone.
    public static func deactivate(
        account: SteamGuardAccount,
        scheme: Int = 1
    ) async throws -> Bool {
        guard let session = account.session, let token = session.accessToken, !token.isEmpty else {
            throw SteamError.needsAuthentication
        }
        guard let revocationCode = account.revocationCode, !revocationCode.isEmpty else {
            throw SteamError.loginFailed(
                "This account has no revocation code stored, so it cannot be deactivated from here."
            )
        }

        let data = try await SteamWeb.post(
            "\(SteamEndpoints.api)/ITwoFactorService/RemoveAuthenticator/v1",
            query: [URLQueryItem(name: "access_token", value: token)],
            body: [
                URLQueryItem(name: "revocation_code", value: revocationCode),
                URLQueryItem(name: "revocation_reason", value: "1"),
                URLQueryItem(name: "steamguard_scheme", value: String(scheme)),
            ]
        )

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any]
        else { throw SteamError.badResponse }

        if let success = response["success"] as? Bool, success { return true }
        if let remaining = response["revocation_attempts_remaining"] as? NSNumber {
            throw SteamError.loginFailed(
                "Steam rejected that revocation code. \(remaining.intValue) attempts remaining."
            )
        }
        return false
    }

    // MARK: - Helpers

    public static func normalizePhoneNumber(_ number: String) -> String {
        var result = number.filter { $0.isNumber || $0 == "+" }
        if result.hasPrefix("+") {
            result = "+" + result.dropFirst().filter(\.isNumber)
        }
        return result
    }

    public static func isPlausiblePhoneNumber(_ number: String) -> Bool {
        number.hasPrefix("+") && number.dropFirst().count >= 6
    }

    private func post(_ url: String, body: [URLQueryItem] = []) async throws -> Data {
        try await SteamWeb.post(
            url,
            query: [URLQueryItem(name: "access_token", value: try accessToken)],
            body: body
        )
    }

    /// Steam wraps every one of these replies in a single `response` object.
    private func json(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SteamError.badResponse
        }
        return (root["response"] as? [String: Any]) ?? [:]
    }
}
