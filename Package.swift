// swift-tools-version: 6.2

// A manifest describing twenty-odd targets does not decompose the way a
// source file does — SwiftPM wants one file — and most of the length here
// is comments earning their keep. `file_length` has no line-scoped form,
// so the blanket disable is the only expression available; `.swiftlint.yml`
// permits it for this rule alone.
// swiftlint:disable file_length

import Foundation
import PackageDescription

/// When SWIFT_SHEET_MUSIC_ANDROID=1 is exported, the manifest assembles a
/// reduced targets/products array that excludes Apple-only sub-libraries
/// (Layout / UI / PDF / Audio / RenderPreviews). See
/// docs/superpowers/specs/2026-05-18-android-toolchain-design.md.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"
/// When SWIFT_SHEET_MUSIC_WASM=1 is exported, the manifest also offers the
/// `WasmSizeProbe` executable that `Scripts/wasm-size.sh` measures. Kept behind
/// a flag so the shipping package shape carries no extra product.
let isWasm = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_WASM"] == "1"

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
    // Re-exports FoundationEssentials where it exists and Foundation
    // elsewhere; see Sources/SheetMusicFoundation for why.
    .target(name: "SheetMusicFoundation"),
    .target(
        name: "SheetMusicCore",
        dependencies: ["SheetMusicFoundation"],
    ),
    .target(
        name: "SheetMusicXMLTools",
        dependencies: ["SheetMusicCore", "SheetMusicFoundation"],
    ),
    .target(
        name: "SheetMusicZip",
        // Linux and Android link the system libz and resolve `import zlib`
        // against their sysroot's modulemap. The WebAssembly SDK ships
        // neither, so under SWIFT_SHEET_MUSIC_WASM the vendored target
        // below supplies a module of the same name. Apple uses
        // `Compression` and needs nothing here.
        dependencies: isWasm ? ["SheetMusicFoundation", "zlib"] : ["SheetMusicFoundation"],
        linkerSettings: [
            .linkedLibrary("z", .when(platforms: [.linux, .android])),
        ],
    ),
    .target(
        name: "SheetMusicMSCX",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ],
    ),
    .target(
        name: "SheetMusicMusicXML",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicXMLTools",
            "SheetMusicZip",
        ],
    ),
    .target(
        name: "SheetMusicMIDI",
        dependencies: ["SheetMusicCore", "SheetMusicFoundation"],
    ),
    .target(
        name: "SheetMusicAudioCore",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicMIDI",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
    ),
    .target(
        name: "SheetMusic",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicMIDI",
        ],
    ),
    .target(
        name: "SheetMusicLayout",
        dependencies: ["SheetMusicCore", "SheetMusicFoundation"],
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
            "SheetMusicFoundation",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
    ),
    // The platform-neutral half of what SheetMusicAndroidJNI used to be: the layout and
    // draw-program bridge, the handle tables, the SMuFL metrics table and the wire codecs.
    // Split out so a WebAssembly bridge reuses this implementation instead of growing a
    // second one beside it.
    //
    // The `native*` entry points cannot live here. swift-java's jextract scans exactly one
    // directory — `--input-swift <the target's own source dir>`, JExtractSwiftPlugin.swift:72 —
    // and its `--depends-on` flag resolves types from dependency modules rather than
    // generating entry points from them. So the entry points keep their residency in
    // SheetMusicAndroidJNI and everything they call lives here.
    //
    // Deliberately depends on neither SheetMusicPDF nor SwiftJava: PDF has no wasm shape and is
    // still on the Foundation umbrella, and SwiftJava does not cross-compile to WASI. Keeping
    // both out is what makes this target buildable for wasm at all — see `Scripts/wasm-size.sh`
    // and CLAUDE.md's "Size is the constraint". SheetMusicEditWire is fine by contrast: it has
    // built for wasm since Wirelet 0.4.1, and on Android it is already linked into this same
    // `.so` through SheetMusicAndroidJNI, so naming it here adds no second image.
    .target(
        name: "SheetMusicBridgeCore",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicLayout",
            "SheetMusicMIDI",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicAudioCore",
            "SheetMusicEditWire",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
    ),
    .target(
        name: "SheetMusicAndroidJNI",
        dependencies: [
            "SheetMusicBridgeCore",
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
]

// `SheetMusicAudioCoreTests` above cross-builds for WebAssembly as it stands —
// its only dependencies are AudioCore and Core, both portable. `SheetMusicTests`
// cannot, and not only because its Apple-framework guards are spelled
// `#if !os(Android)`, which is true on WASI: it depends on `SheetMusicAudio`,
// whose Apple half reaches `CSequencerHostTime` and so `AVFAudio/AVFAudio.h`,
// and on `SheetMusicAndroidJNI`, which pulls SwiftJava. Widening the source
// guards would not move either of those. Getting the whole suite onto wasm is
// its own piece of work; until then the wasm-only suite below is what runs.
if isWasm {
    targets += [
        .testTarget(
            name: "SheetMusicWasmBridgeTests",
            dependencies: [
                "SheetMusicWasmBridge",
                "SheetMusicAudioCore",
                "SheetMusicBridgeCore",
                "SheetMusicCore",
                "SheetMusicFoundation",
                "SheetMusicMIDI",
                "SheetMusicMSCX",
            ],
            path: "Tests/SheetMusicWasmBridgeTests",
        ),
    ]
} else {
    targets += [
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
                "SheetMusicBridgeCore",
                "SheetMusicEditWire",
                "SheetMusicAudioCore",
                .product(name: "Wirelet", package: "swift-wirelet"),
                "SheetMusicFoundation",
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
                "SheetMusicBridgeCore",
                "SheetMusicEditWire",
                "SheetMusicLayoutApple",
                "SheetMusicUI",
                "SheetMusicAudio",
                .product(name: "SwiftySynth", package: "swiftysynth"),
                "SheetMusicAudioSwiftySynth",
                "SheetMusicPDF",
                .product(name: "Wirelet", package: "swift-wirelet"),
                "SheetMusicFoundation",
                "SheetMusicXMLTools",
                "SheetMusicZip",
            ],
            resources: [
                .process("Resources"),
            ],
        ),
    ]
}

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
    ]
    // Apple-only by construction, so it is left out of the wasm shape for the
    // same reason `SheetMusicTests` is: `swift package … js test` builds every
    // declared test target, and one that cannot cross-compile fails the run
    // before the portable suites get to speak.
    if !isWasm {
        targets += [
            .testTarget(
                name: "SheetMusicAudioAppleTests",
                dependencies: [
                    "SheetMusicAudioApple",
                    "SheetMusicAudioCore",
                    "SheetMusicCore",
                    "SheetMusicMIDI",
                ],
            ),
            // Build-time generators for the WebAssembly package's assets. Not
            // products: their output is committed, so a consumer never builds
            // them, and they are macOS-only because that is where CoreText is —
            // which is the whole reason the metrics table is generated rather
            // than measured in the browser. See Tools/GenBravuraMetrics.
            .executableTarget(
                name: "GenBravuraMetrics",
                dependencies: ["SheetMusicLayout", "SheetMusicLayoutApple"],
                path: "Tools/GenBravuraMetrics",
            ),
            // The fixtures Web/sheet-music-web/test reads: a draw program
            // carrying every opcode, a small score, and what the Apple build
            // computes for it. Generated rather than typed, because the point is
            // that the two builds agree.
            .executableTarget(
                name: "GenWebFixtures",
                dependencies: [
                    "SheetMusicAudioCore",
                    "SheetMusicBridgeCore",
                    "SheetMusicCore",
                    "SheetMusicLayout",
                    "SheetMusicLayoutApple",
                    "SheetMusicMIDI",
                    "SheetMusicMSCX",
                ],
                path: "Tools/GenWebFixtures",
            ),
        ]
    }
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

if isWasm {
    products += [
        .executable(name: "sheet-music-wasm", targets: ["SheetMusicWasmEntry"]),
    ]
    targets += [
        // Vendored zlib 1.3.1, raw-DEFLATE subset — see Sources/zlib/README.md.
        // Lowercase on purpose: the module name has to match the system
        // module Linux and Android provide, or DeflateZLib.swift would need
        // a per-platform import alias.
        .target(
            name: "zlib",
            path: "Sources/zlib",
            exclude: ["LICENSE", "README.md"],
            cSettings: [
                // The gzip wrapper inside deflate.c / inflate.c is
                // unreachable here — this package only ever asks for raw
                // DEFLATE (windowBits = -15) — and the gz* file-I/O
                // translation units are not vendored at all.
                .define("NO_GZIP"),
            ],
        ),
        // The `@JS` entry points. A library rather than the executable because
        // BridgeJS scans only the target it is attached to — the same residency
        // rule jextract imposes on `SheetMusicAndroidJNI` — and keeping them in
        // a library lets `WasmSizeProbe` link them so the size gate measures
        // them. The thunks reach the executable's export section without being
        // referenced from it; the library archive does not, which is what
        // `SheetMusicWasmEntry/main.swift`'s one call is for.
        .target(
            name: "SheetMusicWasmBridge",
            dependencies: [
                "SheetMusicAudioCore",
                "SheetMusicBridgeCore",
                "SheetMusicCore",
                "SheetMusicFoundation",
                "SheetMusicLayout",
                "SheetMusicMIDI",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ],
            path: "Sources/SheetMusicWasmBridge",
            swiftSettings: [.enableExperimentalFeature("Extern")],
            plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")],
        ),
        .executableTarget(
            name: "SheetMusicWasmEntry",
            dependencies: ["SheetMusicWasmBridge"],
            path: "Sources/SheetMusicWasmEntry",
        ),
        .executableTarget(
            name: "WasmSizeProbe",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicLayout",
                "SheetMusicMIDI",
                "SheetMusicMSCX",
                "SheetMusicEditWire",
                "SheetMusicBridgeCore",
                "SheetMusicWasmBridge",
            ],
            path: "Sources/WasmSizeProbe",
        ),
        // Run natively and under a wasm host to compare the parse of the
        // same file; see Sources/WasmParityProbe/main.swift.
        .executableTarget(
            name: "WasmParityProbe",
            dependencies: [
                "SheetMusicCore",
                "SheetMusicFoundation",
                "SheetMusicMSCX",
            ],
            path: "Sources/WasmParityProbe",
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
    // 0.4.1 imports FoundationEssentials where it exists. Before it, the
    // umbrella arrived through this package and cost ~10 MB brotli in any
    // WebAssembly graph containing SheetMusicAudioCore or
    // SheetMusicEditWire — see CLAUDE.md "WebAssembly build".
    .package(
        url: "https://github.com/jiyimeta/swift-wirelet.git",
        exact: "0.4.1",
    ),
    .package(
        url: "https://github.com/jiyimeta/swiftysynth.git",
        exact: "0.2.0",
    ),
    // Declared unconditionally on purpose. A wasm-only dependency changes
    // `Package.resolved`'s `originHash`, so the file's contents would depend on
    // which manifest shape ran last. Apple and Android never link this, so the
    // only cost is one fetch. `exact:` for the same reason Wirelet is pinned
    // exactly: one `import Foundation` upstream is worth ~10 MB brotli here.
    .package(
        url: "https://github.com/swiftwasm/JavaScriptKit.git",
        exact: "0.57.1",
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
