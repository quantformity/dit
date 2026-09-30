// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectInvestTracker",
    products: [
        .library(name: "DirectInvestTracker", targets: ["DirectInvestTracker"]),
        .executable(name: "dit", targets: ["dit"]),
        .executable(name: "dit-chart", targets: ["dit-chart"])
    ],
    targets: [
        .target(name: "DirectInvestTracker"),
        .executableTarget(
            name: "dit",
            dependencies: ["DirectInvestTracker"]
        ),
        .executableTarget(
            name: "dit-chart",
            dependencies: ["DirectInvestTracker"]
        ),
        .testTarget(
            name: "DirectInvestTrackerTests",
            dependencies: ["DirectInvestTracker"]
        )
    ]
)