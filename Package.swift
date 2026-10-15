// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeStickies",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "MarketData", targets: ["MarketData"]),
        .library(name: "Presentation", targets: ["Presentation"]),
        .library(name: "Widgets", targets: ["Widgets"]),
        .executable(name: "TradeStickies", targets: ["TradeStickies"]),
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
        // UI-independent view logic: number formatting, input parsing, the transaction form model.
        .target(name: "Presentation", dependencies: ["Domain"]),
        .testTarget(name: "PresentationTests", dependencies: ["Presentation", "Domain"]),
        // Sticker view models and SwiftUI views. No AppKit window code here.
        .target(name: "Widgets", dependencies: ["Domain", "Persistence", "MarketData", "Presentation"]),
        .testTarget(name: "WidgetsTests", dependencies: ["Widgets", "Domain", "Persistence", "MarketData", "Presentation"]),
        .executableTarget(name: "TradeStickies", dependencies: ["Domain", "Persistence", "MarketData", "Widgets"], resources: [.process("Resources")]),
        // Throwaway spike for risk R1 (window behaviour). Not used by any other target.
        .executableTarget(name: "WindowSpike"),
    ]
)
