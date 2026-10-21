// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mxlt-utils",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CallQuitsCore", targets: ["CallQuitsCore"]),
        .library(name: "MxltCore", targets: ["MxltCore"])
    ],
    targets: [
        .target(name: "CallQuitsCore"),
        .target(name: "MxltCore"),
        .testTarget(name: "CallQuitsCoreTests", dependencies: ["CallQuitsCore"]),
        .testTarget(name: "MxltCoreTests", dependencies: ["MxltCore"])
    ]
)
