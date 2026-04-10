// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SyncSensorAppDependencies",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "SyncSensorAppDependencies", targets: ["SyncSensorAppDependencies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "SyncSensorAppDependencies",
            dependencies: ["ZIPFoundation"]
        )
    ]
)
