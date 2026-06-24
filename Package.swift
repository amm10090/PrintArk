// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Tabooprint",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "Tabooprint",
            targets: ["Tabooprint"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.3"),
    ],
    targets: [
        .executableTarget(
            name: "Tabooprint",
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
        .testTarget(
            name: "TabooprintTests",
            dependencies: ["Tabooprint"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
