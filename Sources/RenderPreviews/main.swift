#if os(macOS)
import AppKit
import Foundation
import SheetMusic
import SheetMusicCore
import SheetMusicMSCX
import SheetMusicUI
import SwiftUI

// Usage:
//   swift run render-previews [output-dir]
//
// Default output dir is `tmp/previews/`. Writes one PNG per sample Score.
// The tool is macOS 15+ only; it exits cleanly on older OS versions.

guard #available(macOS 15.0, *) else {
    FileHandle.standardError.write(Data(
        "RenderPreviews requires macOS 15+\n".utf8))
    exit(1)
}

@available(macOS 15.0, *)
@MainActor
func run() throws {
    let args = CommandLine.arguments
    let outputDir: URL = args.count > 1
        ? URL(fileURLWithPath: args[1], isDirectory: true)
        : URL(fileURLWithPath: "tmp/previews", isDirectory: true)
    try FileManager.default.createDirectory(
        at: outputDir, withIntermediateDirectories: true)

    let samples: [(name: String, score: Score, size: CGSize)] = [
        ("01-empty",          Samples.empty,         CGSize(width: 600, height: 160)),
        ("02-whole-note",     Samples.wholeNote,     CGSize(width: 600, height: 160)),
        ("03-c-major-scale",  Samples.cMajorScale,   CGSize(width: 900, height: 180)),
        ("04-eighths-beamed", Samples.eighthsBeamed, CGSize(width: 900, height: 180)),
        ("05-piano-grand",    Samples.pianoGrand,    CGSize(width: 900, height: 300)),
        ("06-accidentals",    Samples.accidentals,   CGSize(width: 900, height: 180)),
        ("07-rests",          Samples.rests,         CGSize(width: 900, height: 180)),
        ("08-key-sigs",       Samples.keySignatures, CGSize(width: 900, height: 180)),
        ("09-time-sigs",      Samples.timeSignatures, CGSize(width: 900, height: 180)),
        ("10-dynamics-tempo", Samples.dynamicsTempo, CGSize(width: 900, height: 240)),
        ("11-isolated-flags", Samples.isolatedFlags, CGSize(width: 900, height: 220)),
        ("12-dotted-durations", Samples.dottedDurations, CGSize(width: 900, height: 220)),
        ("13-mixed-beams", Samples.mixedBeams, CGSize(width: 900, height: 220)),
    ]

    for (name, score, size) in samples {
        let view = ScoreView(score: score)
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            print("FAILED to render \(name)")
            continue
        }
        let url = outputDir.appendingPathComponent("\(name).png")
        try writePNG(cg, to: url)
        print("wrote \(url.path) (\(cg.width)×\(cg.height))")
    }

    // Real-world check: parse Example/SheetMusicExample/test.mscx if
    // present and render the first couple of systems. Useful for
    // spot-checking synthesized clefs on staves that rely on MuseScore
    // instrument defaults.
    let examplePath = URL(fileURLWithPath:
        "Example/SheetMusicExample/test.mscx")
    if FileManager.default.fileExists(atPath: examplePath.path),
       let data = try? Data(contentsOf: examplePath),
       let realScore = try? SheetMusic.loadScore(mscxData: data) {
        let trimmed = trimFirstMeasures(of: realScore, count: 2)
        let realView = ScoreView(score: trimmed)
            .frame(width: 1600, height: CGFloat(trimmed.staves.count * 120))
            .padding(16)
            .background(Color.white)
        let realRenderer = ImageRenderer(content: realView)
        realRenderer.scale = 2
        if let cg = realRenderer.cgImage {
            let url = outputDir.appendingPathComponent(
                "90-real-mscx.png")
            try writePNG(cg, to: url)
            print("wrote \(url.path) (\(cg.width)×\(cg.height))")
        }
    } else {
        print("skipped 90-real-mscx: Example/SheetMusicExample/test.mscx not readable")
    }

    // Smoke test: ScoreView with NO explicit frame must fall back to the
    // score's natural size — this is what happens inside a ScrollView
    // that proposes nil width/height. A broken ScoreView would collapse
    // to ~10×10 here.
    let scrollScore = Samples.cMajorScale
    let noFrameView = ScoreView(score: scrollScore)
        .padding()
        .background(Color.white)
    let noFrameRenderer = ImageRenderer(content: noFrameView)
    noFrameRenderer.scale = 2
    if let cg = noFrameRenderer.cgImage {
        let url = outputDir.appendingPathComponent(
            "99-unconstrained.png")
        try writePNG(cg, to: url)
        print("wrote \(url.path) (\(cg.width)×\(cg.height))")
        if cg.width < 400 {
            FileHandle.standardError.write(Data(
                "WARNING: unconstrained ScoreView collapsed to \(cg.width)px wide — the ScrollView-compatible minWidth floor may have regressed.\n".utf8))
        }
    }
}

/// Keep the first `count` measures of every staff so a large real-world
/// score renders into a reasonable canvas.
@available(macOS 15.0, *)
func trimFirstMeasures(of score: Score, count: Int) -> Score {
    let trimmedStaves = score.staves.map { staff in
        StaffContent(
            id: staff.id,
            measures: Array(staff.measures.prefix(count)))
    }
    return Score(
        division: score.division,
        parts: score.parts,
        staves: trimmedStaves,
        metaTags: score.metaTags)
}

@available(macOS 15.0, *)
func writePNG(_ cg: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        struct NoPNGData: Error {}
        throw NoPNGData()
    }
    try data.write(to: url)
}

if #available(macOS 15.0, *) {
    try MainActor.assumeIsolated { try run() }
}
#endif
