#if os(macOS)
import AppKit
import Foundation
import SheetMusic
import SheetMusicCore
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
