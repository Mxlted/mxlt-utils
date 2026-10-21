// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mxlt-utils",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MxltUtils", targets: ["MxltUtils"])],
    targets: [
        .target(name: "CallQuitsCore"),
        .target(name: "MxltCore"),
        .executableTarget(name: "MxltUtils", dependencies: ["CallQuitsCore", "MxltCore"]),
        .testTarget(name: "CallQuitsCoreTests", dependencies: ["CallQuitsCore"]),
        .testTarget(name: "MxltCoreTests", dependencies: ["MxltCore"]),
        .testTarget(name: "MxltUtilsTests", dependencies: ["MxltUtils", "CallQuitsCore", "MxltCore"])
    ]
)
