// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeSticker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .executable(name: "WindowSpike", targets: ["WindowSpike"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        // Throwaway spike for risk R1 (window behaviour). Not used by any other target.
        .executableTarget(name: "WindowSpike"),
    ]
)
