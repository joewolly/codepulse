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
    targets: [
        .executableTarget(
            name: "CodePulse",
            path: "Sources/CodePulse"
        ),
        .testTarget(
            name: "CodePulseTests",
            dependencies: ["CodePulse"],
            path: "Tests/CodePulseTests"
        )
    ]
)
