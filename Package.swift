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
        .executableTarget(
            name: "SDA",
            dependencies: ["SteamAuthKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SteamAuthKitTests",
            dependencies: ["SteamAuthKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
