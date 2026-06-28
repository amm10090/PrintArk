// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PrintArk",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PrintArkKit",
            targets: ["PrintArk"]
        ),
        .executable(
            name: "PrintArk",
            targets: ["PrintArkApp"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.3"),
    ],
    targets: [
        .target(
            name: "PrintArk",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "PrintArkApp",
            dependencies: ["PrintArk"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "PrintArkTests",
            dependencies: ["PrintArk"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
