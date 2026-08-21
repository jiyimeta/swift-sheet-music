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
    // Exported on Android too: the target's Android shape excludes every Apple-only file (the CGPDFScanner
    // walker, the PDFKit entry, PDF export, the SwiftUI views) and depends only on Core + Layout, so a
    // cross-compiling consumer can use the importer — `PDFImporter.parseUsingSwiftReader`,
    // `parseWithGeometryUsingSwiftReader`, `summaryUsingSwiftReader` — without dragging Apple frameworks in.
    .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
]

var targets: [Target] = [
    .executableTarget(
        name: "GenSMuFLTables",
        path: "Sources/GenSMuFLTables",
    ),
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
        dependencies: [
            "SheetMusicCore",
            "SheetMusicMIDI",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
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
    .target(
        name: "SheetMusicPDF",
        dependencies: isAndroid
            ? ["SheetMusicCore", "SheetMusicLayout"]
            : ["SheetMusicCore", "SheetMusicLayout", "SheetMusicLayoutApple", "SheetMusicUI"],
        // Apple-only files (CGPDFScanner walker, PDFDocument entry, PDF export,
        // SwiftUI/PDFKit views) are excluded from the Android build; Android
        // parses via the Foundation-only pure-Swift reader.
        exclude: isAndroid ? [
            "PageChromeRenderer.swift",
            "PDFPageLayerView.swift",
            "PDFPageView.swift",
            "PDFExporter.swift",
            "EngravingPage.swift",
            "Import/PDFImporter+ContentStream.swift",
            "Import/PDFImporter+ContentStream+Operators.swift",
            "Import/PDFImporter+AppleEntry.swift",
            "Import/FontCascade/PDFFontProgram.swift",
            "Import/FontCascade/GlyphBitmap.swift",
            "Import/FontCascade/ShapeDescriptor.swift",
            "Import/FontCascade/BravuraExemplars.swift",
            "Import/FontCascade/GlyphClassifier.swift",
            "Import/FontCascade/GlyphClassifier+MusicFontGate.swift",
            "Import/FontCascade/GlyphClassifier+GlyphIDResolve.swift",
            // NOTE: SimpleFontEncoding / SimpleFontTextDecoder / AdobeGlyphList
            // are Foundation-only and stay in the Android build — the shared
            // `PDFPageState` holds the decoder registry, and the Android
            // front-end can start filling it once its reader parses
            // `/Encoding`. Until then the registry is simply empty there.
        ] : [],
    ),
    // Always built (like SheetMusicAndroidJNI itself below): SheetMusicTests depends on it in both the
    // Android and non-Android shapes, and SheetMusicAndroidJNI's own sources import it unconditionally.
    // Only its *product* (below, in the `if isAndroid` block) is Android-gated — the same split
    // SheetMusicAndroidJNI's target/product pair already uses.
    //
    // The `Path/` and `Intent/` subdirectories are load-bearing for the Kotlin side, not just tidiness:
    // wirelet's Gradle codegen scans exactly one directory per source set, and `:SheetMusicAudioAndroid`
    // scans `Path/` to emit the ScoreItemID / NoteID / StaffAddress / ClefAnchor codecs its playback engine
    // needs. Adding an `@WireFormat` type to `Path/` therefore emits a Kotlin codec into
    // `io.github.jiyimeta.sheetmusic.audio.serialization` that expects a hand-written model class of the same
    // name; put anything the audio module does not need in `Intent/`.
    .target(
        name: "SheetMusicEditWire",
        dependencies: [
            "SheetMusicCore",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
    ),
    .target(
        name: "SheetMusicAndroidJNI",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicPDF",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicMIDI",
            "SheetMusicAudioCore",
            "SheetMusicEditWire",
            .product(name: "Wirelet", package: "swift-wirelet"),
            .product(name: "SwiftJava", package: "swift-java"),
        ],
        exclude: [
            "swift-java.config",
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
        plugins: [
            .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
        ],
    ),
    .testTarget(
        name: "SheetMusicAudioCoreTests",
        dependencies: ["SheetMusicAudioCore", "SheetMusicCore"],
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
            "SheetMusicAndroidJNI",
            "SheetMusicEditWire",
            "SheetMusicAudioCore",
            .product(name: "Wirelet", package: "swift-wirelet"),
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ] : [
            "SheetMusic",
            "SheetMusicCore",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicAndroidJNI",
            "SheetMusicEditWire",
            "SheetMusicLayoutApple",
            "SheetMusicUI",
            "SheetMusicAudio",
            .product(name: "SwiftySynth", package: "swiftysynth"),
            "SheetMusicAudioSwiftySynth",
            "SheetMusicPDF",
            .product(name: "Wirelet", package: "swift-wirelet"),
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
        .library(name: "SheetMusicAudioApple", targets: ["SheetMusicAudioApple"]),
        // Pure-Swift, MIT SoundFont2 playback backend (SwiftySynth). Works on
        // iOS + macOS, App-Store clean — the default stealing-free synth.
        .library(name: "SheetMusicAudioSwiftySynth", targets: ["SheetMusicAudioSwiftySynth"]),
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
            name: "CSequencerHostTime",
            path: "Sources/CSequencerHostTime",
        ),
        .target(
            name: "SheetMusicAudioApple",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicAudioCore",
                "CSequencerHostTime",
            ],
        ),
        .target(
            name: "SheetMusicAudio",
            dependencies: [
                "SheetMusicAudioCore",
                "SheetMusicAudioApple",
            ],
        ),
        .target(
            name: "SheetMusicAudioSwiftySynth",
            dependencies: [
                .product(name: "SwiftySynth", package: "swiftysynth"),
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicAudioCore",
                "SheetMusicAudioApple",
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
        .testTarget(
            name: "SheetMusicAudioAppleTests",
            dependencies: [
                "SheetMusicAudioApple",
                "SheetMusicAudioCore",
                "SheetMusicCore",
                "SheetMusicMIDI",
            ],
        ),
    ]
}

if isAndroid {
    products += [
        .library(
            name: "SheetMusicAndroidJNI",
            type: .dynamic,
            targets: ["SheetMusicAndroidJNI"],
        ),
        // Not `.dynamic`: Folino's `FolinoEditorJNI` and this package's `SheetMusicAndroidJNI` are separate
        // `.so`s, each linking its own copy of the wire code. That's fine — the wire is pure code with no
        // shared state, and what must match between the two images is the *schema*, which now has exactly
        // one declaration instead of two hand-maintained copies.
        .library(
            name: "SheetMusicEditWire",
            targets: ["SheetMusicEditWire"],
        ),
    ]
    targets += [
        .target(
            name: "CJNI",
            path: "Sources/CJNI",
            publicHeadersPath: ".",
        ),
    ]
}

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.4.0"),
    // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x
    // (`OutputProtocol.standardOutput` / `ErrorOutputProtocol.standardError`).
    // swift-subprocess 0.5.0 removed those static members, which breaks the
    // jextract tool's compile under the swift-6.3.2 toolchain. Pin to 0.4.0 — the
    // last release where that API still exists — so JExtractSwiftPlugin builds.
    // Aligns with Folino's swift-java pin so a single swiftkit-core satisfies both.
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
    .package(
        url: "https://github.com/jiyimeta/swift-wirelet.git",
        exact: "0.4.1",
    ),
    .package(
        url: "https://github.com/jiyimeta/swiftysynth.git",
        exact: "0.2.0",
    ),
]

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
