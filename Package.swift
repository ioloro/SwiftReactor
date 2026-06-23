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
        // Runnable per-model demo: `swift run SwiftReactorDemo` on macOS.
        // See Examples/SwiftReactorDemo/README.md for setup.
        .executable(name: "SwiftReactorDemo", targets: ["SwiftReactorDemo"]),
    ],
    dependencies: [
        // Pinned to 140.x because 141+ ships a broken macOS slice (missing
        // public headers). Re-evaluate when stasel/WebRTC resolves
        // https://github.com/stasel/WebRTC/issues -- "Fix xcframework public
        // headers for macOS and other slices".
        .package(url: "https://github.com/stasel/WebRTC", "140.0.0"..<"141.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftReactor",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        // Testable helpers used by the demo executable. Lives outside
        // the SwiftReactor library because it's demo-app boilerplate,
        // not SDK surface — but it's its own target so the test
        // target can link it (SwiftPM doesn't let test targets link
        // executable targets directly).
        .target(
            name: "SwiftReactorDemoSupport",
            dependencies: ["SwiftReactor"],
            path: "Examples/SwiftReactorDemoSupport"
        ),
        .testTarget(
            name: "SwiftReactorTests",
            dependencies: ["SwiftReactor"]
        ),
        .testTarget(
            name: "SwiftReactorDemoSupportTests",
            dependencies: ["SwiftReactorDemoSupport", "SwiftReactor"],
            path: "Tests/SwiftReactorDemoSupportTests"
        ),
        .executableTarget(
            name: "SwiftReactorDemo",
            dependencies: ["SwiftReactor", "SwiftReactorDemoSupport"],
            path: "Examples/SwiftReactorDemo"
        ),
    ]
)
