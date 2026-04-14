// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-musescore-parser",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "MuseScoreParser",
            targets: ["MuseScoreParser"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "MuseScoreParser",
            dependencies: [
                "ZIPFoundation",
            ]
        ),
        .testTarget(
            name: "MuseScoreParserTests",
            dependencies: ["MuseScoreParser"],
            resources: [
                .copy("Resources/midi01.mscx"),
                .copy("Resources/midi01-ref.mid"),
            ]
        ),
    ]
)
