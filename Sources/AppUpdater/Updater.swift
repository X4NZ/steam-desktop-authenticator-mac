import AppKit
import Foundation

/// Checks GitHub Releases for a newer build, and installs it.
///
/// The app is ad-hoc signed rather than notarized, so it is distributed as a zip
/// attached to a release rather than through the App Store. Updating therefore
/// means replacing the bundle on disk — which cannot be done from inside the
/// running app, hence the handoff to a detached shell script at the end.
public enum Updater {

    /// `owner/repo`, taken from Info.plist so the build script owns it.
    public static var repository: String? {
        Bundle.main.object(forInfoDictionaryKey: "SDAUpdateRepository") as? String
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public struct Release: Sendable, Identifiable {
        public var id: String { version }
        public var version: String
        public var name: String
        public var notes: String
        public var pageURL: URL
        public var downloadURL: URL?
        public var downloadSize: Int64
        public var publishedAt: Date?
    }

    public enum UpdateError: LocalizedError {
        case notConfigured
        case noReleases
        case noAsset
        case notInstallable(String)
        case downloadFailed(String)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "This build has no update repository configured."
            case .noReleases:
                return "No releases have been published yet."
            case .noAsset:
                return "That release has no downloadable app attached to it."
            case .notInstallable(let detail):
                return detail
            case .downloadFailed(let detail):
                return "Download failed: \(detail)"
            case .installFailed(let detail):
                return "Install failed: \(detail)"
            }
        }
    }

    // MARK: - Checking

    /// Returns the latest release when it is newer than what is running.
    public static func checkForUpdate() async throws -> Release? {
        guard let repository else { throw UpdateError.notConfigured }

        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SDA-Mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw UpdateError.noReleases }
            guard http.statusCode == 200 else {
                throw UpdateError.downloadFailed("GitHub returned HTTP \(http.statusCode).")
            }
        }

        guard let release = parseRelease(data) else { throw UpdateError.noReleases }
        return isNewer(release.version, than: currentVersion) ? release : nil
    }

    /// Pulls a release out of GitHub's JSON. Separate from the request so the
    /// shape of that payload can be tested without network access.
    public static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let pageString = json["html_url"] as? String,
              let pageURL = URL(string: pageString)
        else { return nil }

        // Prefer a zipped .app asset; that is what the release workflow attaches.
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let asset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }

        return Release(
            version: normalize(tag),
            name: (json["name"] as? String) ?? tag,
            notes: (json["body"] as? String) ?? "",
            pageURL: pageURL,
            downloadURL: (asset?["browser_download_url"] as? String).flatMap(URL.init),
            downloadSize: (asset?["size"] as? NSNumber)?.int64Value ?? 0,
            publishedAt: (json["published_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
        )
    }

    // MARK: - Version comparison

    public static func normalize(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        return trimmed
    }

    /// Numeric component comparison, so 1.10.0 sorts above 1.9.0 (which a plain
    /// string compare gets wrong). Any pre-release suffix is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            normalize(version)
                .prefix { $0.isNumber || $0 == "." }
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }

        let left = components(candidate)
        let right = components(current)

        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Installing

    /// Downloads the release and swaps it in, then relaunches.
    ///
    /// `progress` is called on the main actor with a 0...1 fraction.
    public static func downloadAndInstall(
        _ release: Release,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let downloadURL = release.downloadURL else { throw UpdateError.noAsset }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError.notInstallable(
                "This copy is not running from an .app bundle, so it cannot update itself."
            )
        }

        // Fail before downloading if the bundle cannot be replaced anyway.
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notInstallable(
                "\(parent.path) is not writable, so the app cannot replace itself. "
                    + "Move it to /Applications, or download the update manually."
            )
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let zipURL = workDirectory.appendingPathComponent("update.zip")
        try await download(from: downloadURL, to: zipURL, progress: progress)

        // ditto handles the archives `ditto -c -k` produces, keeping symlinks
        // and resource forks intact; `unzip` does not.
        let extractDirectory = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDirectory.path])

        guard let newBundle = findApp(in: extractDirectory) else {
            throw UpdateError.installFailed("The downloaded archive contains no .app.")
        }

        // Refuse anything that is not this same app.
        let newInfo = NSDictionary(contentsOf: newBundle.appendingPathComponent("Contents/Info.plist"))
        let newIdentifier = newInfo?["CFBundleIdentifier"] as? String
        guard newIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.installFailed(
                "The downloaded app has a different bundle identifier, so it was not installed."
            )
        }

        try swapAndRelaunch(newBundle: newBundle, currentBundle: bundleURL, workDirectory: workDirectory)
    }

    private static func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let response = try await FileDownload(destination: destination, progress: progress).run(url)

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
        }
        progress(1.0)
    }

    private static func findApp(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        if let app = contents.first(where: { $0.pathExtension == "app" }) { return app }

        // Some archives nest the app one level down.
        for item in contents where item.hasDirectoryPath {
            if let nested = findApp(in: item) { return nested }
        }
        return nil
    }

    /// Hands the swap to a detached script, because a running bundle cannot
    /// replace itself: the script waits for this process to exit first.
    private static func swapAndRelaunch(
        newBundle: URL,
        currentBundle: URL,
        workDirectory: URL
    ) throws {
        let script = workDirectory.appendingPathComponent("install.sh")
        let backup = currentBundle.deletingLastPathComponent()
            .appendingPathComponent(".\(currentBundle.lastPathComponent).old")

        // Paths arrive as arguments rather than interpolated into the body, so
        // nothing in a path can be read as shell syntax.
        let source = """
        #!/bin/bash
        # Installs the downloaded update once the old app has quit.
        set -e

        pid="$1"
        current="$2"
        replacement="$3"
        backup="$4"
        workdir="$5"

        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done

        rm -rf "$backup"
        # Keep the old bundle until the new one is in place, so a failure here
        # leaves a working app behind rather than nothing at all.
        if ! mv "$current" "$backup"; then exit 1; fi

        if ! ditto "$replacement" "$current"; then
            mv "$backup" "$current"
            exit 1
        fi

        xattr -dr com.apple.quarantine "$current" 2>/dev/null || true
        rm -rf "$backup"
        open "$current"
        rm -rf "$workdir"
        """

        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            currentBundle.path,
            newBundle.path,
            backup.path,
            workDirectory.path,
        ]
        try process.run()

        // Quit so the script, which is already waiting on this PID, can take
        // over. exit() is the backstop if something refuses to terminate.
        // Returning instead of parking a thread leaves nothing blocked.
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed(output.isEmpty ? "exit \(process.terminationStatus)" : output)
        }
        return output
    }
}

/// Downloads a file to disk, reporting progress as it goes.
///
/// This was once a `for try await byte in bytes` loop accumulating into
/// `Data`. That held the whole archive in memory and, measured against the
/// 1.5 MB v1.2.1 asset, took 8.9s where a plain fetch took 0.44s — the cost
/// is the per-byte async iteration, so buffering the appends does not help
/// (8.4s when tried). The async `download` methods are fast but deliver no
/// progress at all, not even through a delegate, so the classic download task
/// is the only way to get both. Measured at 0.52s with progress intact.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var lastReported = 0.0

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URLResponse {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Throttled: a callback per packet would swamp the main actor.
        guard fraction - lastReported > 0.01 else { return }
        lastReported = fraction
        progress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file has to be moved here: it is gone once this method returns.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: downloadTask.response ?? URLResponse())
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // Success already resumed above.
        continuation?.resume(throwing: Updater.UpdateError.downloadFailed(error.localizedDescription))
        continuation = nil
    }
}
