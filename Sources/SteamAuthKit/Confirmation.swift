import Foundation

/// One pending mobile confirmation: a trade, a market listing, an account change.
public struct Confirmation: Identifiable, Hashable, Sendable, Codable {
    public var id: UInt64
    /// Steam calls this `nonce`; it is the per-confirmation key sent back on accept.
    public var nonce: UInt64
    public var creatorID: UInt64
    public var headline: String
    public var summary: [String]
    public var acceptLabel: String
    public var cancelLabel: String
    public var iconURL: String?
    public var typeName: String?
    public var creationTime: Int64?
    public var type: ConfirmationType

    enum CodingKeys: String, CodingKey {
        case id, nonce, headline, summary, accept, cancel, icon, type
        case creatorID = "creator_id"
        case typeName = "type_name"
        case creationTime = "creation_time"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenientUInt64(.id) ?? 0
        nonce = container.lenientUInt64(.nonce) ?? 0
        creatorID = container.lenientUInt64(.creatorID) ?? 0
        headline = container.lenientString(.headline) ?? "Confirmation"
        summary = (try? container.decodeIfPresent([String].self, forKey: .summary))?
            .filter { !$0.isEmpty } ?? []
        acceptLabel = container.lenientString(.accept) ?? "Confirm"
        cancelLabel = container.lenientString(.cancel) ?? "Cancel"
        iconURL = container.lenientString(.icon)
        typeName = container.lenientString(.typeName)
        creationTime = container.lenientInt64(.creationTime)
        type = ConfirmationType(rawValue: container.lenientInt(.type) ?? 0) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(id), forKey: .id)
        try container.encode(String(nonce), forKey: .nonce)
        try container.encode(headline, forKey: .headline)
        try container.encode(summary, forKey: .summary)
        try container.encode(type.rawValue, forKey: .type)
    }

    public var createdAt: Date? {
        creationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public enum ConfirmationType: Int, Sendable, CaseIterable {
    case unknown = 0
    case test = 1
    case trade = 2
    case marketListing = 3
    case featureOptOut = 4
    case phoneNumberChange = 5
    case accountRecovery = 6
    case apiKeyRegistration = 9

    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .test: return "Test"
        case .trade: return "Trade"
        case .marketListing: return "Market listing"
        case .featureOptOut: return "Feature opt-out"
        case .phoneNumberChange: return "Phone number change"
        case .accountRecovery: return "Account recovery"
        case .apiKeyRegistration: return "API key registration"
        }
    }

    public var symbolName: String {
        switch self {
        case .trade: return "arrow.left.arrow.right"
        case .marketListing: return "tag"
        case .phoneNumberChange: return "phone"
        case .accountRecovery: return "lifepreserver"
        case .apiKeyRegistration: return "key"
        default: return "questionmark.circle"
        }
    }
}

private struct ConfirmationsResponse: Decodable {
    var success: Bool
    var message: String?
    var needauth: Bool?
    var conf: [Confirmation]?

    enum CodingKeys: String, CodingKey { case success, message, needauth, conf }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = container.lenientBool(.success) ?? false
        message = container.lenientString(.message)
        needauth = container.lenientBool(.needauth)
        conf = try? container.decodeIfPresent([Confirmation].self, forKey: .conf)
    }
}

private struct OperationResponse: Decodable {
    var success: Bool
    var message: String?

    enum CodingKeys: String, CodingKey { case success, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = container.lenientBool(.success) ?? false
        message = container.lenientString(.message)
    }
}

// MARK: - Fetching and acting on confirmations

extension SteamGuardAccount {
    /// Fetches pending confirmations from the mobile endpoint.
    ///
    /// This is the JSON list the Steam mobile app uses, so no HTML scraping and
    /// no embedded web view are needed — unlike SDA, which renders Steam's page
    /// in WebView2.
    public func fetchConfirmations() async throws -> [Confirmation] {
        guard let session else { throw SteamError.noSession }

        let time = await SteamTime.shared.currentTime()
        let query = try confirmationQueryItems(forTime: time, tag: "list")
        let cookies = session.cookieHeader()

        let data = try await SteamWeb.get(
            "\(SteamEndpoints.community)/mobileconf/getlist",
            query: query,
            cookies: cookies
        )

        guard let response = try? JSONDecoder().decode(ConfirmationsResponse.self, from: data) else {
            // A non-JSON body here is nearly always Steam's login page.
            throw SteamError.needsAuthentication
        }

        if response.needauth == true { throw SteamError.needsAuthentication }
        guard response.success else {
            throw SteamError.confirmationsFailed(response.message ?? "Steam rejected the request")
        }
        return response.conf ?? []
    }

    public func accept(_ confirmation: Confirmation) async throws {
        try await send([confirmation], operation: .allow)
    }

    public func deny(_ confirmation: Confirmation) async throws {
        try await send([confirmation], operation: .cancel)
    }

    public func accept(_ confirmations: [Confirmation]) async throws {
        try await send(confirmations, operation: .allow)
    }

    public func deny(_ confirmations: [Confirmation]) async throws {
        try await send(confirmations, operation: .cancel)
    }

    enum ConfirmationOperation: String {
        case allow
        case cancel

        /// Steam signs these requests with a tag that differs from the op name.
        var tag: String { self == .allow ? "accept" : "reject" }
    }

    private func send(_ confirmations: [Confirmation], operation: ConfirmationOperation) async throws {
        guard !confirmations.isEmpty else { return }
        guard let session else { throw SteamError.noSession }

        let time = await SteamTime.shared.currentTime()
        var body = try confirmationQueryItems(forTime: time, tag: operation.tag)
        body.insert(URLQueryItem(name: "op", value: operation.rawValue), at: 0)

        let isMulti = confirmations.count > 1
        if isMulti {
            for confirmation in confirmations {
                body.append(URLQueryItem(name: "cid[]", value: String(confirmation.id)))
                body.append(URLQueryItem(name: "ck[]", value: String(confirmation.nonce)))
            }
        } else {
            body.append(URLQueryItem(name: "cid", value: String(confirmations[0].id)))
            body.append(URLQueryItem(name: "ck", value: String(confirmations[0].nonce)))
        }

        let endpoint = isMulti ? "multiajaxop" : "ajaxop"
        let data = try await SteamWeb.post(
            "\(SteamEndpoints.community)/mobileconf/\(endpoint)",
            body: body,
            cookies: session.cookieHeader(),
            referer: "\(SteamEndpoints.community)/mobileconf/conf"
        )

        let response = try? JSONDecoder().decode(OperationResponse.self, from: data)
        guard response?.success == true else {
            throw SteamError.confirmationsFailed(response?.message ?? "Steam rejected the confirmation")
        }
    }
}
