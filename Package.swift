// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectInvestTracker",
    products: [
        .library(name: "DirectInvestTracker", targets: ["DirectInvestTracker"])
    ],
    targets: [
        .target(name: "DirectInvestTracker"),
        .testTarget(
            name: "DirectInvestTrackerTests",
            dependencies: ["DirectInvestTracker"]
        )
    ]
)