// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "dit",
    products: [
        .executable(name: "dit", targets: ["dit"]),
        .executable(name: "dit-chart", targets: ["dit-chart"])
    ],
    targets: [
        .target(name: "DitCore"),
        .executableTarget(
            name: "dit",
            dependencies: ["DitCore"]
        ),
        .executableTarget(
            name: "dit-chart",
            dependencies: ["DitCore"]
        ),
        .testTarget(
            name: "DitCoreTests",
            dependencies: ["DitCore"]
        )
    ]
)
