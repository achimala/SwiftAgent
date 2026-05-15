// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentKitMLX",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AgentKitMLX",
            targets: ["AgentKitMLX"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AgentKitMLX",
            dependencies: [
                .product(name: "AgentKit", package: "AgentKit"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
