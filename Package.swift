// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mgmail",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MgmailApp",
            path: "Sources/MgmailApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
