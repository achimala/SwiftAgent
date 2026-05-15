// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "AgentKit",
            targets: ["AgentKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .binaryTarget(
            name: "Python",
            path: "Vendor/Python.xcframework"
        ),
        .binaryTarget(
            name: "AgentKitISH",
            path: "Vendor/AgentKitISH.xcframework"
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
            name: "CHermesPython",
            dependencies: ["Python"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CHermesShell",
            dependencies: ["ios_system"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AgentKit",
            dependencies: [
                "CHermesShell",
                "AgentKitISH",
                "CHermesPython",
                "awk",
                "dash",
                "files",
                "ios_system",
                "shell",
                "text",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        ),
    ]
)
