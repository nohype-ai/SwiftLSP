// swift-tools-version:5.6

import PackageDescription

let package = Package(
    name: "SwiftLSP",
    platforms: [.iOS(.v13), .tvOS(.v13), .macOS(.v10_15), .watchOS(.v6)],
    products: [
        .library(
            name: "SwiftLSP",
            targets: ["SwiftLSP"]),
    ],
    dependencies: [
//        .package(path: "../FoundationToolz"),
        .package(
            url: "https://github.com/nohype-ai/FoundationToolz.git",
            exact: "0.5.10"
        ),
        .package(
            url: "https://github.com/nohype-ai/SwiftyToolz.git",
            exact: "0.5.8"
        )
    ],
    targets: [
        .target(
            name: "SwiftLSP",
            dependencies: ["FoundationToolz", "SwiftyToolz"],
            path: "Sources"
        ),
        .testTarget(
            name: "SwiftLSPTests",
            dependencies: ["SwiftLSP", "FoundationToolz", "SwiftyToolz"],
            path: "Tests"
        ),
    ]
)
