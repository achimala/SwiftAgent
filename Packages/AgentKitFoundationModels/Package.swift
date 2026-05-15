// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentKitFoundationModels",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AgentKitFoundationModels",
            targets: ["AgentKitFoundationModels"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "AgentKitFoundationModels",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
            ],
            linkerSettings: [
                .linkedFramework("FoundationModels"),
            ]
        ),
    ]
)
