// swift-tools-version:5.5
// Runestone 0.5.2 with one fix; see PADCODE.md.

import PackageDescription

let package = Package(
    name: "Runestone",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "Runestone", targets: ["Runestone"])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.20.9"))
    ],
    targets: [
        .target(name: "Runestone", dependencies: [
            .product(name: "TreeSitter", package: "tree-sitter")
        ], resources: [
            .copy("PrivacyInfo.xcprivacy"),
            .process("TextView/Appearance/Theme.xcassets")
        ])
    ]
)
