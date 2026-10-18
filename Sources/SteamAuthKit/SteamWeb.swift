import Foundation

public enum SteamEndpoints {
    public static let api = "https://api.steampowered.com"
    public static let community = "https://steamcommunity.com"
    public static let store = "https://store.steampowered.com"
}

/// Shared HTTP layer for every Steam request.
///
/// Steam only serves the mobile confirmation flow to clients that look like the
/// Android app, so the mobile user agent is not optional.
public enum SteamWeb {
    public static let mobileUserAgent = "Dalvik/2.1.0 (Linux; U; Android 9; Valve Steam App Version/3)"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": mobileUserAgent]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: - Percent encoding

    /// `URLComponents` leaves `+` unescaped in query values, which silently
    /// corrupts the base64 confirmation signatures Steam expects. Encode by hand.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }

    public static func queryString(_ items: [URLQueryItem]) -> String {
        items
            .map { "\(encode($0.name))=\(encode($0.value ?? ""))" }
            .joined(separator: "&")
    }

    // MARK: - Requests

    public static func get(
        _ urlString: String,
        query: [URLQueryItem] = [],
        cookies: String? = nil
    ) async throws -> Data {
        var full = urlString
        if !query.isEmpty {
            full += (full.contains("?") ? "&" : "?") + queryString(query)
        }
        guard let url = URL(string: full) else { throw SteamError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }

        return try await perform(request)
    }

    /// Form-encoded POST. Steam's older `ITwoFactorService` and `/mobileconf/`
    /// endpoints accept this and answer with JSON.
    public static func post(
        _ urlString: String,
        query: [URLQueryItem] = [],
        body: [URLQueryItem] = [],
        cookies: String? = nil,
        referer: String? = nil
    ) async throws -> Data {
        var full = urlString
        if !query.isEmpty {
            full += (full.contains("?") ? "&" : "?") + queryString(query)
        }
        guard let url = URL(string: full) else { throw SteamError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if let cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue(SteamEndpoints.community, forHTTPHeaderField: "Origin")
        }
        request.httpBody = Data(queryString(body).utf8)

        return try await perform(request)
    }

    // MARK: - Protobuf service calls

    /// Calls a protobuf Steam service method.
    ///
    /// The WebAPI accepts the request message as base64 in `input_protobuf_encoded`
    /// and replies with the raw response message. Errors arrive as an `x-eresult`
    /// header rather than an HTTP status, so they are surfaced from there.
    static func callService(
        interface: String,
        method: String,
        version: Int = 1,
        request: ProtoWriter,
        accessToken: String? = nil,
        httpMethod: String = "POST"
    ) async throws -> ProtoMessage {
        var urlString = "\(SteamEndpoints.api)/\(interface)/\(method)/v\(version)/"
        var query = [URLQueryItem]()
        if let accessToken, !accessToken.isEmpty {
            query.append(URLQueryItem(name: "access_token", value: accessToken))
        }

        let encoded = request.data.base64EncodedString()
        var urlRequest: URLRequest

        if httpMethod == "GET" {
            // GET takes the message base64url-encoded in the query string.
            let urlSafe = encoded
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            query.append(URLQueryItem(name: "input_protobuf_encoded", value: urlSafe))
            urlString += "?" + queryString(query)
            guard let url = URL(string: urlString) else { throw SteamError.badURL }
            urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
        } else {
            if !query.isEmpty { urlString += "?" + queryString(query) }
            guard let url = URL(string: urlString) else { throw SteamError.badURL }
            urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue(
                "application/x-www-form-urlencoded; charset=UTF-8",
                forHTTPHeaderField: "Content-Type"
            )
            urlRequest.httpBody = Data("input_protobuf_encoded=\(encode(encoded))".utf8)
        }

        let (data, response) = try await send(urlRequest)

        if let http = response as? HTTPURLResponse {
            let eresult = http.value(forHTTPHeaderField: "x-eresult").flatMap(Int.init) ?? 1
            let message = http.value(forHTTPHeaderField: "x-error_message")

            // 1 is EResult.OK. Anything else means the body is not a usable response.
            if eresult != 1 {
                throw SteamError.apiError(eresult: eresult, message: message)
            }
        }

        return ProtoMessage(data)
    }

    // MARK: - Plumbing

    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw SteamError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw SteamError.network(error.localizedDescription)
        }
    }
}

// MARK: - Errors

public enum SteamError: LocalizedError {
    case badURL
    case network(String)
    case httpStatus(Int)
    case apiError(eresult: Int, message: String?)
    case badResponse
    case noSession
    case missingDeviceID
    case missingIdentitySecret
    case needsAuthentication
    case confirmationsFailed(String)
    case loginFailed(String)
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .badURL:
            return "Could not build a valid Steam URL."
        case .network(let detail):
            return "Network error: \(detail)"
        case .httpStatus(let code):
            return "Steam returned HTTP \(code)."
        case .apiError(let eresult, let message):
            if let message, !message.isEmpty { return "Steam error \(eresult): \(message)" }
            return "Steam error \(eresult): \(EResult.describe(eresult))"
        case .badResponse:
            return "Steam returned a response that could not be understood."
        case .noSession:
            return "This account has no saved Steam session. Log in again."
        case .missingDeviceID:
            return "This account is missing its device ID, so confirmations cannot be signed."
        case .missingIdentitySecret:
            return "This account is missing its identity secret, so confirmations cannot be signed."
        case .needsAuthentication:
            return "Your Steam session has expired. Log in again."
        case .confirmationsFailed(let detail):
            return "Could not load confirmations: \(detail)"
        case .loginFailed(let detail):
            return detail
        case .rateLimited:
            return "Steam is rate limiting this account. Wait a few minutes and try again."
        }
    }
}

/// The handful of `EResult` values worth naming in the UI.
enum EResult {
    static func describe(_ value: Int) -> String {
        switch value {
        case 5: return "invalid password"
        case 8: return "a required field was missing or malformed"
        case 10: return "Steam is busy; try again"
        case 15: return "access denied"
        case 16: return "timed out"
        case 20: return "Steam service unavailable"
        case 29: return "an authenticator is already active on this account"
        case 65: return "two-factor code mismatch"
        case 84: return "rate limit exceeded"
        case 88: return "two-factor code mismatch"
        default: return "unknown error"
        }
    }
}
