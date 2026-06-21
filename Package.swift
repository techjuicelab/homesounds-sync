// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeSoundsSync",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "HomeSoundsSync",
            path: "Sources/HomeSoundsSync",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
