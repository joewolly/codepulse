// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodePulse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodePulse", targets: ["CodePulse"]),
        .executable(name: "codepulse-integration", targets: ["CodePulseIntegrationCLI"]),
        .executable(name: "codepulsectl", targets: ["CodePulseControlCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .target(
            name: "CodePulseIntegration",
            path: "Sources/CodePulseIntegration"
        ),
        .executableTarget(
            name: "CodePulse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "CodePulseIntegration"
            ],
            path: "Sources/CodePulse"
        ),
        .executableTarget(
            name: "CodePulseIntegrationCLI",
            dependencies: ["CodePulseIntegration"],
            path: "Sources/CodePulseIntegrationCLI"
        ),
        .target(
            name: "CodePulseControlClient",
            dependencies: ["CodePulseIntegration"],
            path: "Sources/CodePulseControlClient"
        ),
        .executableTarget(
            name: "CodePulseControlCLI",
            dependencies: ["CodePulseControlClient"],
            path: "Sources/CodePulseControlCLI"
        ),
        .testTarget(
            name: "CodePulseTests",
            dependencies: ["CodePulse", "CodePulseIntegration", "CodePulseControlClient"],
            path: "Tests/CodePulseTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
