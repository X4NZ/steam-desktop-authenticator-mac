import Foundation
import Testing

@testable import AppUpdater

struct VersionComparisonTests {

    @Test("A higher version is detected")
    func newer() {
        #expect(Updater.isNewer("1.1.0", than: "1.0.0"))
        #expect(Updater.isNewer("2.0.0", than: "1.9.9"))
        #expect(Updater.isNewer("1.0.1", than: "1.0.0"))
    }

    @Test("The same or older version is not an update")
    func notNewer() {
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("0.9.0", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.1"))
    }

    @Test("Components compare numerically, not as strings")
    func numericOrdering() {
        // A plain string compare puts "1.10.0" below "1.9.0", which would strand
        // everyone on 1.9 forever.
        #expect(Updater.isNewer("1.10.0", than: "1.9.0"))
        #expect(Updater.isNewer("1.0.10", than: "1.0.9"))
        #expect(!Updater.isNewer("1.9.0", than: "1.10.0"))
    }

    @Test("A leading v on the tag is ignored")
    func tagPrefix() {
        #expect(Updater.normalize("v1.2.3") == "1.2.3")
        #expect(Updater.normalize("V1.2.3") == "1.2.3")
        #expect(Updater.normalize(" 1.2.3 ") == "1.2.3")
        #expect(Updater.isNewer("v1.1.0", than: "1.0.0"))
    }

    @Test("Versions of differing length compare sensibly")
    func differingLength() {
        #expect(Updater.isNewer("1.1", than: "1.0.9"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
        #expect(Updater.isNewer("1.0.0.1", than: "1.0.0"))
    }

    @Test("Pre-release suffixes do not break parsing")
    func suffixes() {
        #expect(Updater.isNewer("1.2.0-beta1", than: "1.1.0"))
        #expect(!Updater.isNewer("1.0.0-rc1", than: "1.0.0"))
    }

    @Test("Nonsense versions are treated as not newer rather than crashing")
    func garbage() {
        #expect(!Updater.isNewer("", than: "1.0.0"))
        #expect(!Updater.isNewer("not-a-version", than: "1.0.0"))
        #expect(Updater.isNewer("1.0.0", than: "garbage"))
    }
}

struct ReleaseParsingTests {

    /// Trimmed to the fields the updater reads, in GitHub's actual shape.
    private let payload = """
    {
      "tag_name": "v1.2.0",
      "name": "Version 1.2.0",
      "body": "- Added drag and drop\\n- Fixed a crash",
      "html_url": "https://github.com/owner/repo/releases/tag/v1.2.0",
      "published_at": "2026-10-18T12:00:00Z",
      "assets": [
        {
          "name": "notes.txt",
          "browser_download_url": "https://example.com/notes.txt",
          "size": 12
        },
        {
          "name": "Steam.Desktop.Authenticator.zip",
          "browser_download_url": "https://example.com/app.zip",
          "size": 3145728
        }
      ]
    }
    """

    @Test("A release payload is parsed into its fields")
    func parsesRelease() throws {
        let release = try #require(Updater.parseRelease(Data(payload.utf8)))

        #expect(release.version == "1.2.0")
        #expect(release.name == "Version 1.2.0")
        #expect(release.notes.contains("drag and drop"))
        #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v1.2.0"))
        #expect(release.publishedAt != nil)
    }

    @Test("The zipped app is chosen over other assets")
    func picksZipAsset() throws {
        let release = try #require(Updater.parseRelease(Data(payload.utf8)))
        #expect(release.downloadURL?.absoluteString == "https://example.com/app.zip")
        #expect(release.downloadSize == 3_145_728)
    }

    @Test("A release with no zip still parses, just without a download")
    func noZipAsset() throws {
        let json = """
        {
          "tag_name": "v1.0.0",
          "html_url": "https://github.com/owner/repo/releases/tag/v1.0.0",
          "assets": []
        }
        """
        let release = try #require(Updater.parseRelease(Data(json.utf8)))
        #expect(release.downloadURL == nil)
        #expect(release.version == "1.0.0")
    }

    @Test("Malformed payloads return nil instead of throwing")
    func malformed() {
        #expect(Updater.parseRelease(Data("not json".utf8)) == nil)
        #expect(Updater.parseRelease(Data("{}".utf8)) == nil)
        #expect(Updater.parseRelease(Data()) == nil)
    }
}
