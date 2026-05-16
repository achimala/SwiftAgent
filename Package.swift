// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftAgent",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftAgentCore",
            targets: ["SwiftAgentCore"]
        ),
        .library(
            name: "SwiftAgent",
            targets: ["SwiftAgent"]
        ),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "Python",
            path: "Vendor/Python.xcframework"
        ),
        .binaryTarget(
            name: "SwiftAgentISH",
            path: "Vendor/SwiftAgentISH.xcframework"
        ),
        .binaryTarget(
            name: "ios_system",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/ios_system.xcframework.zip",
            checksum: "6973c1c14a66cdc110a5be7d62991af4546124bd0d9773b5391694b3a93a5be0"
        ),
        .binaryTarget(
            name: "awk",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/awk.xcframework.zip",
            checksum: "6898b01913261eee194edcb464212d4af6bc33355b1e286bbbd17f3f878c1706"
        ),
        .binaryTarget(
            name: "files",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/files.xcframework.zip",
            checksum: "02d6522f5e1adc3b472f7aaa53910f049e6c5829e07c7e3005cf2a0d5f9f423a"
        ),
        .binaryTarget(
            name: "shell",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/shell.xcframework.zip",
            checksum: "78d71828b89c83741a8f7e857f0d065da72952558fd7deb806f5748c3801fd95"
        ),
        .binaryTarget(
            name: "text",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/text.xcframework.zip",
            checksum: "2450f309d0793490136a24f9af02c42fb712b327571cb44312fe330e87a156f2"
        ),
        .binaryTarget(
            name: "dash",
            url: "https://github.com/holzschu/ios_system/releases/download/Auxiliary/dash.xcframework.zip",
            checksum: "9a30ac6b3780dd68d2268d10467902214e32333e980c59090faa6099f0d250fc"
        ),
        .target(
            name: "SwiftAgentCore"
        ),
        .target(
            name: "CHermesPython",
            dependencies: [
                .target(name: "Python", condition: .when(platforms: [.iOS])),
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CHermesShell",
            dependencies: [
                .target(name: "ios_system", condition: .when(platforms: [.iOS])),
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftAgent",
            dependencies: [
                "SwiftAgentCore",
                "CHermesPython",
                .target(name: "CHermesShell", condition: .when(platforms: [.iOS])),
                .target(name: "SwiftAgentISH", condition: .when(platforms: [.iOS])),
                .target(name: "awk", condition: .when(platforms: [.iOS])),
                .target(name: "dash", condition: .when(platforms: [.iOS])),
                .target(name: "files", condition: .when(platforms: [.iOS])),
                .target(name: "ios_system", condition: .when(platforms: [.iOS])),
                .target(name: "shell", condition: .when(platforms: [.iOS])),
                .target(name: "text", condition: .when(platforms: [.iOS])),
            ],
            resources: [
                .copy("Resources/Python"),
                .copy("Resources/iSH"),
                .copy("Resources/Shell"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentCoreTests",
            dependencies: ["SwiftAgentCore"]
        ),
    ]
)
