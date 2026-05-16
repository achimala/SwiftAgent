// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftAgentFoundationModels",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SwiftAgentFoundationModels",
            targets: ["SwiftAgentFoundationModels"]
        ),
    ],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .target(
            name: "SwiftAgentFoundationModels",
            dependencies: [
                .product(name: "SwiftAgent", package: "SwiftAgent"),
            ],
            linkerSettings: [
                .linkedFramework("FoundationModels"),
            ]
        ),
    ]
)
