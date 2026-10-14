// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeSticker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
