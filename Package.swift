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
    .library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),
    .library(name: "SheetMusicAudioCore", targets: ["SheetMusicAudioCore"]),
]

var targets: [Target] = [
    .target(name: "SheetMusicCore"),
    .target(
        name: "SheetMusicXMLTools",
        dependencies: ["SheetMusicCore"],
    ),
    .target(
        name: "SheetMusicZip",
        linkerSettings: [
            .linkedLibrary("z", .when(platforms: [.linux, .android])),
        ],
    ),
    .target(
        name: "SheetMusicMSCX",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ],
    ),
    .target(
        name: "SheetMusicMusicXML",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ],
    ),
    .target(
        name: "SheetMusicMIDI",
        dependencies: ["SheetMusicCore"],
    ),
    .target(
        name: "SheetMusicAudioCore",
        dependencies: ["SheetMusicCore", "SheetMusicMIDI"],
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
    .target(
        name: "SheetMusicLayout",
        dependencies: ["SheetMusicCore"],
    ),
    .testTarget(
        name: "SheetMusicTests",
        dependencies: isAndroid ? [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicAudioCore",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ] : [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicLayoutApple",
            "SheetMusicUI",
            "SheetMusicAudio",
            "SheetMusicPDF",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ],
        resources: [
            .process("Resources"),
        ],
    ),
]

if !isAndroid {
    products += [
        .library(name: "SheetMusicLayoutApple", targets: ["SheetMusicLayoutApple"]),
        .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
        .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
        .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
        .executable(name: "render-previews", targets: ["RenderPreviews"]),
    ]
    targets += [
        .target(
            name: "SheetMusicLayoutApple",
            dependencies: ["SheetMusicCore", "SheetMusicLayout"],
            resources: [.process("Fonts/Resources")],
        ),
        .target(
            name: "SheetMusicUI",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicLayout",
                "SheetMusicLayoutApple",
            ],
        ),
        .target(
            name: "SheetMusicAudio",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicAudioCore",
            ],
        ),
        .target(
            name: "SheetMusicPDF",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicLayout",
                "SheetMusicLayoutApple",
                "SheetMusicUI",
            ],
        ),
        .executableTarget(
            name: "RenderPreviews",
            dependencies: [
                "SheetMusic",
                "SheetMusicLayout",
                "SheetMusicLayoutApple",
                "SheetMusicUI",
            ],
        ),
    ]
}

let packageDependencies: [Package.Dependency] = []

let package = Package(
    name: "swift-sheet-music",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
