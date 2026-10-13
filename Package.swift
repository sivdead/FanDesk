// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanDesk", platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FanStorage", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "FanCore", dependencies: ["FanStorage"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FanDesk", dependencies: ["FanCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FanDeskHelper", dependencies: ["FanCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FanDeskProbe", dependencies: ["FanCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CoreChecks", dependencies: ["FanCore"], path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)])
    ])
