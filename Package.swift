// swift-tools-version: 6.2

import Foundation
import PackageDescription

/// When SWIFT_SHEET_MUSIC_ANDROID=1 is exported, the manifest assembles a
/// reduced targets/products array that excludes Apple-only sub-libraries
/// (Layout / UI / PDF / Audio / RenderPreviews). See
/// docs/superpowers/specs/2026-05-18-android-toolchain-design.md.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"

var products: [Product] = [
    .library(name: "SheetMusic", targets: ["SheetMusic"]),
    .library(name: "SheetMusicCore", targets: ["SheetMusicCore"]),
    .library(name: "SheetMusicMSCX", targets: ["SheetMusicMSCX"]),
    .library(name: "SheetMusicMusicXML", targets: ["SheetMusicMusicXML"]),
    .library(name: "SheetMusicMIDI", targets: ["SheetMusicMIDI"]),
]

var targets: [Target] = [
    .target(name: "SheetMusicCore"),
    .target(
        name: "SheetMusicXMLTools",
        dependencies: ["SheetMusicCore"],
    ),
    .target(
        name: "SheetMusicMSCX",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicXMLTools",
            "ZIPFoundation",
        ],
    ),
    .target(
        name: "SheetMusicMusicXML",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicXMLTools",
            "ZIPFoundation",
        ],
    ),
    .target(
        name: "SheetMusicMIDI",
        dependencies: ["SheetMusicCore"],
    ),
    .target(
        name: "SheetMusic",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicMIDI",
        ],
    ),
    .testTarget(
        name: "SheetMusicTests",
        dependencies: isAndroid ? [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicXMLTools",
            "ZIPFoundation",
        ] : [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicUI",
            "SheetMusicAudio",
            "SheetMusicPDF",
            "SheetMusicXMLTools",
            "ZIPFoundation",
        ],
        resources: [
            .process("Resources"),
        ],
    ),
]

if !isAndroid {
    products += [
        .library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),
        .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
        .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
        .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
        .executable(name: "render-previews", targets: ["RenderPreviews"]),
    ]
    targets += [
        .target(
            name: "SheetMusicLayout",
            dependencies: ["SheetMusicCore"],
            resources: [.process("Fonts/Resources")],
        ),
        .target(
            name: "SheetMusicUI",
            dependencies: ["SheetMusicCore", "SheetMusicLayout"],
        ),
        .target(
            name: "SheetMusicAudio",
            dependencies: ["SheetMusicCore", "SheetMusicMIDI"],
        ),
        .target(
            name: "SheetMusicPDF",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicLayout",
                "SheetMusicUI",
            ],
        ),
        .executableTarget(
            name: "RenderPreviews",
            dependencies: ["SheetMusic", "SheetMusicLayout", "SheetMusicUI"],
        ),
    ]
}

let package = Package(
    name: "swift-sheet-music",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: targets,
)
