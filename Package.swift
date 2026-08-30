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
/// reduced targets/products array that excludes the Apple-only sub-libraries
/// (LayoutApple / UI / Audio / AudioApple / AudioSwiftySynth / RenderPreviews);
/// Layout and PDF (in its import-only Android shape) still ship. See
/// docs/superpowers/specs/2026-05-18-android-toolchain-design.md.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_ANDROID"] == "1"
/// When SWIFT_SHEET_MUSIC_WASM=1 is exported, the manifest also offers the
/// `WasmSizeProbe` executable that `Scripts/wasm-size.sh` measures. Kept behind
/// a flag so the shipping package shape carries no extra product.
let isWasm = ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_WASM"] == "1"

/// Linker flags every WebAssembly target here carries. Empty off the wasm path, so the Apple and Android builds —
/// and any consumer resolving this package by version — never see `.unsafeFlags`.
///
/// wasm-ld gives the shadow stack 128 KiB by default and the Swift wasm SDK's toolset adds nothing, which is two
/// orders of magnitude below what Apple and Android hand a thread. Worse, the default layout is
/// `[data][stack][heap]` with the stack growing *down* into `.bss`, so an overflow does not trap: it overwrites
/// whatever static memory sits below — including the allocator's own state — and the run dies much later inside
/// an unrelated `malloc`, with an out-of-bounds trap that names none of the code responsible. The recursive
/// edit-intent decoder found this the hard way; see `NestedEditIntentWire`.
///
/// - `-z stack-size=1048576` — 8x the default. Still a rounding error against a wasm heap that grows into the
///   hundreds of MiB, and it buys real margin for recursive decoders and for the layout engine's fattest frames
///   (38 KiB in one closure alone).
/// - `--stack-first` — puts the stack below all data, so the next overflow runs off address 0 and traps at the
///   function responsible instead of corrupting memory silently. wasm-ld requires `--global-base` to be at least
///   the stack size alongside it.
///
/// These live on the targets, not on `swift package -Xlinker`: a global `-Xlinker` also reaches the macOS host
/// plugin tools (SwiftSyntax / BridgeJS / Wirelet macros), whose `ld` rejects wasm-ld options outright.
let wasmStackLinkerSettings: [LinkerSetting] = isWasm ? [
    .unsafeFlags([
        "-Xlinker", "-z", "-Xlinker", "stack-size=1048576",
        "-Xlinker", "--stack-first",
        "-Xlinker", "--global-base=1048576",
    ]),
] : []

var products: [Product] = [
    .library(name: "SheetMusic", targets: ["SheetMusic"]),
    .library(name: "SheetMusicCore", targets: ["SheetMusicCore"]),
    .library(name: "SheetMusicMSCX", targets: ["SheetMusicMSCX"]),
    .library(name: "SheetMusicMusicXML", targets: ["SheetMusicMusicXML"]),
    .library(name: "SheetMusicMIDI", targets: ["SheetMusicMIDI"]),
    // Exported so a consumer that parses score files itself never has to re-spell the format table. Folino's
    // Android JNI libraries link it directly for exactly that reason.
    .library(name: "SheetMusicLoader", targets: ["SheetMusicLoader"]),
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
    // The single format-dispatch. Static and unconditional: it is linked into every image that has to turn bytes
    // into a `Score`, and on Android that is several separate `.so`s in one process, each with its own
    // SheetMusicCore copy. A `.dynamic` product could not serve them — a `Score` cannot cross between two copies —
    // so sharing the *decision* as source, compiled into each image, is the only shape that unifies it.
    .target(
        name: "SheetMusicLoader",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicFoundation",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicMIDI",
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
            "SheetMusicLoader",
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
    // Always declared: Android and Apple host tests reach it through SheetMusicAndroidJNI,
    // while WebAssembly reaches it through SheetMusicBridgeCore. Only its *product*
    // (below, in the `if isAndroid` block) is Android-gated because the Swift target
    // itself has no JNI or Apple dependency.
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
    // and docs/development/webassembly.md's "Size gates". SheetMusicEditWire is fine by contrast: it has
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
            "SheetMusicLoader",
            .product(name: "Wirelet", package: "swift-wirelet"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
    ),
    .testTarget(
        name: "SheetMusicAudioCoreTests",
        dependencies: ["SheetMusicAudioCore", "SheetMusicCore"],
    ),
]

// `SheetMusicAudioCoreTests` above cross-builds for WebAssembly as it stands —
// its only dependencies are AudioCore and Core, both portable. The wasm
// `SheetMusicTests` shape below uses the Android dependency list minus
// SheetMusicAndroidJNI and the explicit Wirelet dependency; non-portable test
// files are excluded by the named test-support guards.
if isWasm {
    let sheetMusicTestsSwiftSettings: [SwiftSetting] = [
        .define("SHEET_MUSIC_HAS_PREOPENED_TEST_RESOURCES"),
    ]

    targets += [
        .testTarget(
            name: "SheetMusicWasmBridgeTests",
            dependencies: [
                "SheetMusicWasmBridge",
                "SheetMusicAudioCore",
                "SheetMusicBridgeCore",
                "SheetMusicCore",
                "SheetMusicEditWire",
                "SheetMusicFoundation",
                "SheetMusicMIDI",
                "SheetMusicMSCX",
            ],
            path: "Tests/SheetMusicWasmBridgeTests",
            linkerSettings: wasmStackLinkerSettings,
        ),
        .testTarget(
            name: "SheetMusicTests",
            dependencies: [
                "SheetMusic",
                "SheetMusicCore",
                "SheetMusicMIDI",
                "SheetMusicMSCX",
                "SheetMusicMusicXML",
                "SheetMusicLayout",
                "SheetMusicBridgeCore",
                "SheetMusicLoader",
                "SheetMusicEditWire",
                "SheetMusicAudioCore",
                "SheetMusicFoundation",
                "SheetMusicXMLTools",
                "SheetMusicZip",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: sheetMusicTestsSwiftSettings,
            linkerSettings: wasmStackLinkerSettings,
        ),
    ]
} else {
    var sheetMusicTestsSwiftSettings: [SwiftSetting] = [
        .define("SHEET_MUSIC_HAS_FOUNDATION_XML_REFERENCE_ORACLE"),
    ]

    if !isAndroid {
        sheetMusicTestsSwiftSettings += [
            .define("SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT"),
            // JNI bridge tests currently run in the Apple-host SheetMusicTests shape.
            // The Android cross-build links SheetMusicAndroidJNI to compile portable
            // callers, but it does not execute the Swift JNI test files there.
            .define("SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT"),
        ]
    }

    // The untracked PDF spike harnesses (Tests/SheetMusicTests/PDF*SpikeTests.swift,
    // excluded via .git/info/exclude) wrap their bodies in `#if SM_PDF_SPIKE`. They
    // read a private corpus from the local disk and are measurement probes, not
    // gates — and because SwiftPM compiles every file under Tests/ regardless of
    // git, an API drift in an un-updated spike file used to break `swift test` for
    // everyone. Opt in explicitly when running them:
    //   SWIFT_SHEET_MUSIC_PDF_SPIKE=1 swift test --filter PDFCorpus
    if ProcessInfo.processInfo.environment["SWIFT_SHEET_MUSIC_PDF_SPIKE"] == "1" {
        sheetMusicTestsSwiftSettings += [
            .define("SM_PDF_SPIKE"),
        ]
    }

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
                "SheetMusicLoader",
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
                "SheetMusicLoader",
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
            swiftSettings: sheetMusicTestsSwiftSettings,
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

if !isWasm {
    targets += [
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
                "SheetMusicEditWire",
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
            // The shipping artifact needs this more than the tests do: `applyEditIntentBytes` decodes bytes the
            // browser hands it, on this same shadow stack.
            linkerSettings: wasmStackLinkerSettings,
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
            // Same flags as the shipping entry point, so what the size gate measures is what ships.
            linkerSettings: wasmStackLinkerSettings,
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
            linkerSettings: wasmStackLinkerSettings,
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
    // SheetMusicEditWire — see docs/development/webassembly.md ("Size gates").
    .package(
        url: "https://github.com/jiyimeta/swift-wirelet.git",
        exact: "0.5.0",
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
