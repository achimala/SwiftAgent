// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HermesAgentKit",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "HermesAgentKit",
            targets: ["HermesAgentKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "Python",
            path: "Vendor/Python.xcframework"
        ),
        .target(
            name: "CHermesPython",
            dependencies: ["Python"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "HermesAgentKit",
            dependencies: ["CHermesPython"],
            resources: [
                .copy("Resources/Python"),
            ]
        ),
    ]
)
