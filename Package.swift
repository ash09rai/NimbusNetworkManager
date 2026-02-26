// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NimbusNetworkKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "NimbusNetworkCore", targets: ["NimbusNetworkCore"]),
        .library(name: "NimbusTransfer", targets: ["NimbusTransfer"]),
        .library(name: "NimbusSockets", targets: ["NimbusSockets"]),
        .library(name: "NimbusNetworkKit", targets: ["NimbusNetworkKit"])
    ],
    targets: [
        .target(
            name: "NimbusNetworkCore",
            path: "Sources/NimbusNetworkCore"
        ),
        .target(
            name: "NimbusTransfer",
            dependencies: ["NimbusNetworkCore"],
            path: "Sources/NimbusTransfer"
        ),
        .target(
            name: "NimbusSockets",
            dependencies: ["NimbusNetworkCore"],
            path: "Sources/NimbusSockets"
        ),
        .target(
            name: "NimbusNetworkKit",
            dependencies: ["NimbusNetworkCore", "NimbusTransfer", "NimbusSockets"],
            path: "Sources/NimbusNetworkKit"
        ),
        .testTarget(
            name: "NimbusNetworkCoreTests",
            dependencies: ["NimbusNetworkCore"],
            path: "Tests/NimbusNetworkCoreTests"
        ),
        .testTarget(
            name: "NimbusTransferTests",
            dependencies: ["NimbusTransfer", "NimbusNetworkCore"],
            path: "Tests/NimbusTransferTests"
        ),
        .testTarget(
            name: "NimbusSocketsTests",
            dependencies: ["NimbusSockets", "NimbusNetworkCore"],
            path: "Tests/NimbusSocketsTests"
        )
    ]
)
