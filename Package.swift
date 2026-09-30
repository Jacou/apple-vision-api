// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "apple-vision-api",
    platforms: [.macOS(.v27)],
    targets: [
        // HTTP parsing, OpenAI request/response handling and routing. No FoundationModels
        // dependency, so it can be unit-tested on any Mac.
        .target(
            name: "AppleVisionAPICore",
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .executableTarget(
            name: "apple_vision_api",
            dependencies: ["AppleVisionAPICore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "AppleVisionAPICoreTests",
            dependencies: ["AppleVisionAPICore"]
        ),
    ]
)
