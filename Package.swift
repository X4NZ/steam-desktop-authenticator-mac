// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SDA",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SteamAuthKit", targets: ["SteamAuthKit"]),
        .executable(name: "SDA", targets: ["SDA"]),
    ],
    targets: [
        .target(
            name: "SteamAuthKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AppUpdater",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SDA",
            dependencies: ["SteamAuthKit", "AppUpdater"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app target is tested directly rather than by carving the model
        // into its own module: that would mean making every member the views
        // touch public, for no benefit beyond the test seam.
        .testTarget(
            name: "SDATests",
            dependencies: ["SDA", "SteamAuthKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SteamAuthKitTests",
            dependencies: ["SteamAuthKit", "AppUpdater"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
