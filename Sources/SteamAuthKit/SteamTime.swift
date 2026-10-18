import Foundation

/// Keeps local time aligned with Steam's clock.
///
/// Codes are derived from a 30-second window, so a local clock that is more than
/// a few seconds out produces codes Steam rejects. Steam exposes its own time, so
/// the offset is measured once and applied from then on.
public actor SteamTime {
    public static let shared = SteamTime()

    private var offset: Int64 = 0
    private var isAligned = false
    private var lastAligned: Date?

    /// How long an alignment is trusted before it is measured again.
    private static let refreshInterval: TimeInterval = 60 * 60

    /// Current Steam time in seconds since the epoch.
    public func currentTime() async -> Int64 {
        if !isAligned { await align() }
        return Int64(Date().timeIntervalSince1970) + offset
    }

    /// Seconds remaining in the current 30-second code window.
    public func secondsRemaining() async -> Int {
        let time = await currentTime()
        return 30 - Int(time % 30)
    }

    /// Re-measures if the last alignment has gone stale. Cheap to call often.
    public func alignIfStale() async {
        guard let lastAligned else {
            await align()
            return
        }
        if Date().timeIntervalSince(lastAligned) > Self.refreshInterval {
            await align()
        }
    }

    public func align() async {
        let localTime = Int64(Date().timeIntervalSince1970)
        do {
            let data = try await SteamWeb.post(
                "\(SteamEndpoints.api)/ITwoFactorService/QueryTime/v1/",
                body: [URLQueryItem(name: "steamid", value: "0")]
            )
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any],
                  let serverTimeText = response["server_time"],
                  let serverTime = Int64("\(serverTimeText)")
            else { return }

            offset = serverTime - localTime
            isAligned = true
            lastAligned = Date()
        } catch {
            // Falling back to the local clock is better than refusing to show a
            // code; most machines are within a second of correct.
        }
    }

    /// Exposed so the UI can show whether alignment succeeded.
    public var aligned: Bool { isAligned }
    public var currentOffset: Int64 { offset }
}
