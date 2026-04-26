// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-sheet-music",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Umbrella library: re-exports Core + MSCX + MIDI and adds a small
        // convenience façade. Most consumers want this one.
        .library(name: "SheetMusic", targets: ["SheetMusic"]),
        // Score model + shared error type. No format I/O — minimal dependency
        // surface for consumers that just want the data structures.
        .library(name: "SheetMusicCore", targets: ["SheetMusicCore"]),
        // mscx file format I/O (parsing today; writing later).
        .library(name: "SheetMusicMSCX", targets: ["SheetMusicMSCX"]),
        // MusicXML + MXL file format I/O (import only for now).
        .library(name: "SheetMusicMusicXML", targets: ["SheetMusicMusicXML"]),
        // MIDI: in-memory model, score → MIDI rendering, SMF read/write.
        .library(name: "SheetMusicMIDI", targets: ["SheetMusicMIDI"]),
        // SwiftUI views for rendering a Score. macOS 15+ only.
        .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
        // AVFoundation-backed playback: per-staff `AVAudioUnitSampler`s,
        // SoundFont resolution, single-note preview, and (soon) timeline-
        // driven full playback.
        .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
        // PDF export. Reuses SheetMusicUI's layout + drawing pipeline
        // behind an `ImageRenderer` → `CGPDFContext` bridge. macOS 15+
        // / iOS 16+ (same as SheetMusicUI).
        .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
        // Dev tool (not a consumer-facing product): renders sample
        // Scores to PNG for visual inspection of ScoreView.
        .executable(name: "render-previews", targets: ["RenderPreviews"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "SheetMusicCore"),
        // Internal target (no library product): XML tree parsing + node
        // type shared by format targets (mscx today, musicxml soon).
        .target(
            name: "SheetMusicXMLTools",
            dependencies: ["SheetMusicCore"]
        ),
        .target(
            name: "SheetMusicMSCX",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicXMLTools",
                "ZIPFoundation",   // future .mscz (zipped) support
            ]
        ),
        .target(
            name: "SheetMusicMusicXML",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicXMLTools",
                "ZIPFoundation",   // .mxl (zipped MusicXML)
            ]
        ),
        .target(
            name: "SheetMusicMIDI",
            dependencies: ["SheetMusicCore"]
        ),
        .target(
            name: "SheetMusicUI",
            dependencies: ["SheetMusicCore"],
            resources: [.process("Fonts/Resources")]
        ),
        .target(
            name: "SheetMusicAudio",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMIDI",
            ]
        ),
        .target(
            name: "SheetMusicPDF",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicUI",
            ]
        ),
        .target(
            name: "SheetMusic",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMSCX",
                "SheetMusicMusicXML",
                "SheetMusicMIDI",
            ]
        ),
        // Dev tool: renders a set of sample Scores to PNG for visual
        // inspection. Not a published product — only for contributor use.
        .executableTarget(
            name: "RenderPreviews",
            dependencies: ["SheetMusic", "SheetMusicUI"]
        ),
        .testTarget(
            name: "SheetMusicTests",
            dependencies: [
                "SheetMusic",
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicMSCX",
                "SheetMusicMusicXML",
                "SheetMusicUI",
                "SheetMusicAudio",
                "SheetMusicPDF",
                "SheetMusicXMLTools",
                "ZIPFoundation",   // MXLTestBuilder builds .mxl archives at test time
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
