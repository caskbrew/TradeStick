// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeSticker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "MarketData", targets: ["MarketData"]),
        .executable(name: "WindowSpike", targets: ["WindowSpike"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .target(name: "Persistence", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MarketData", dependencies: ["Domain"]),
        .testTarget(name: "MarketDataTests", dependencies: ["MarketData", "Domain"]),
        // Throwaway spike for risk R1 (window behaviour). Not used by any other target.
        .executableTarget(name: "WindowSpike"),
    ]
)
