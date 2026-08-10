// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodePulse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodePulse", targets: ["CodePulse"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "CodePulse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodePulse"
        ),
        .testTarget(
            name: "CodePulseTests",
            dependencies: ["CodePulse"],
            path: "Tests/CodePulseTests"
        )
    ]
)
