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
    targets: [
        .executableTarget(
            name: "Tabooprint",
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
