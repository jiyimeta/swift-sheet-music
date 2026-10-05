// The Windows half of the draw-program parity probe (the Windows roadmap's W0-3): renders the pages RenderPreviews
// exported on the Mac with Direct2DPageRenderer, so the Mac can diff them against its own two renders of the same
// layout.
//
//     windows-render-probe <dir> [<font file>...]
//
// For every `<name>-page.bin` in <dir> (a `DrawProgramCodec` payload, written by `SM_PARITY_EXPORT=1`), reads the
// canvas from `<name>-page.txt` — "widthPx heightPx pxPerMM offsetX offsetY", the numbers the Mac's CoreGraphics walk
// drew with — and writes `<name>-windows.png` beside it. The font files are Bravura and the Edwin faces; without any,
// the ones bundled with SheetMusicRenderWindows (`ScoreSurface.bundledFontFiles`).
//
//     windows-render-probe --onscreen <out dir> [<sheet-music.smft> [<font file>...]]
//
// Measures the onscreen renderer (`ScoreSurface`) in a window on a generated 40-page score and checks the C spec's
// gates (`OnscreenProbe`): prints one line per gate, writes `<out dir>/onscreen.json`, and exits 1 when any fails.
// Without a table it installs the bundled one (`installWindowsFontMetrics()`), and without font files the surface
// loads the bundled faces (`ScoreSurface()`) — what a host that ships nothing of its own does.
//
//     windows-render-probe --pdf <file.pdf> <out dir>
//
// Measures `ScoreSurface` showing a PDF's pages (`PDFProbe`): prints its timings and checks, writes
// `<out dir>/pdf.json`, and exits 1 when a check fails.
//
//     windows-render-probe --write-pdf <score file> <out dir>
//
// Writes the score as a PDF with `ScorePDFWriter` and compares Windows' drawing of it with Direct2D's drawing of the
// same pages (`PDFWriteProbe`); exits 1 when either lacks the other's ink.

import Foundation
import SheetMusicBridgeCore
import SheetMusicRenderWindows

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("windows-render-probe: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--pdf" {
    guard arguments.count == 3 else { fail("usage: windows-render-probe --pdf <file.pdf> <out dir>") }
    let probe = PDFProbe(pdfPath: arguments[1], outputDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true))
    do {
        try exit(probe.run() ? 0 : 1)
    } catch {
        fail("pdf: \(error)")
    }
}

if arguments.first == "--write-pdf" {
    guard arguments.count == 3 else { fail("usage: windows-render-probe --write-pdf <score file> <out dir>") }
    let probe = PDFWriteProbe(
        scorePath: arguments[1], outputDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true),
    )
    do {
        try exit(probe.run() ? 0 : 1)
    } catch {
        fail("write-pdf: \(error)")
    }
}

if arguments.first == "--onscreen" {
    guard arguments.count >= 2 else {
        fail("usage: windows-render-probe --onscreen <out dir> [<metrics> [<font file>...]]")
    }
    let probe = OnscreenProbe(
        outputDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
        metricsPath: arguments.count >= 3 ? arguments[2] : nil, fontFiles: Array(arguments.dropFirst(3)),
    )
    do {
        try exit(probe.run() ? 0 : 1)
    } catch {
        fail("onscreen: \(error)")
    }
}

guard !arguments.isEmpty else { fail("usage: windows-render-probe <dir> [<font file>...]") }
let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
let givenFontFiles = Array(arguments.dropFirst())
let fontFiles = givenFontFiles.isEmpty ? ScoreSurface.bundledFontFiles : givenFontFiles
print("fonts: \(givenFontFiles.isEmpty ? "bundled" : "\(givenFontFiles.count) given"): \(fontFiles)")

let names: [String]
do {
    names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix("-page.bin") }
        .map { String($0.dropLast("-page.bin".count)) }
        .sorted()
} catch {
    fail("cannot list \(directory.path): \(error)")
}

guard !names.isEmpty else { fail("no *-page.bin in \(directory.path)") }

var failures = 0
for name in names {
    do {
        let program = try Data(contentsOf: directory.appendingPathComponent("\(name)-page.bin"))
        guard let page = try DrawProgramCodec.decode(program).first else { throw CocoaError(.fileReadCorruptFile) }
        let canvas = try String(contentsOf: directory.appendingPathComponent("\(name)-page.txt"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard canvas.count == 5 else { throw CocoaError(.fileReadCorruptFile) }
        let output = directory.appendingPathComponent("\(name)-windows.png")
        let clock = ContinuousClock()
        let start = clock.now
        try Direct2DPageRenderer.renderPNG(
            page.commands, widthPx: Int(canvas[0]), heightPx: Int(canvas[1]), pxPerMM: canvas[2],
            offsetPx: (canvas[3], canvas[4]), fontFiles: fontFiles, to: output.path,
        )
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("\(name): \(page.commands.count) commands, \(Int(canvas[0]))x\(Int(canvas[1])) px, "
            + "\(String(format: "%.1f", milliseconds)) ms")
    } catch {
        failures += 1
        print("\(name): FAILED \(error)")
    }
}

print("\(names.count - failures) of \(names.count) rendered")
exit(failures == 0 ? 0 : 1)
