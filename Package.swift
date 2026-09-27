// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectInvestTracker",
    products: [
        .library(name: "DirectInvestTracker", targets: ["DirectInvestTracker"]),
        .executable(name: "dit", targets: ["dit"])
    ],
    targets: [
        .target(name: "DirectInvestTracker"),
        .executableTarget(
            name: "dit",
            dependencies: ["DirectInvestTracker"]
        ),
        .testTarget(
            name: "DirectInvestTrackerTests",
            dependencies: ["DirectInvestTracker"]
        )
    ]
)