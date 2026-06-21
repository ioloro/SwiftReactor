// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftReactor",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiftReactor", targets: ["SwiftReactor"]),
    ],
    dependencies: [
        // WebRTC dependency added in the transport-implementation pass.
        // .package(url: "https://github.com/stasel/WebRTC", from: "137.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftReactor",
            dependencies: [
                // .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "SwiftReactorTests",
            dependencies: ["SwiftReactor"]
        ),
    ]
)
