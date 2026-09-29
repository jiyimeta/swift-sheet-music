// The Windows half of the draw-program parity probe (the Windows roadmap's W0-3): renders the pages RenderPreviews
// exported on the Mac with Direct2DPageRenderer, so the Mac can diff them against its own two renders of the same
// layout.
//
//     windows-render-probe <dir> <font file>...
//
// For every `<name>-page.bin` in <dir> (a `DrawProgramCodec` payload, written by `SM_PARITY_EXPORT=1`), reads the
// canvas from `<name>-page.txt` — "widthPx heightPx pxPerMM offsetX offsetY", the numbers the Mac's CoreGraphics walk
// drew with — and writes `<name>-windows.png` beside it. The font files are Bravura and the Edwin faces.

import Foundation
import SheetMusicBridgeCore
import SheetMusicRenderWindows

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("windows-render-probe: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage: windows-render-probe <dir> <font file>...") }
let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
let fontFiles = Array(arguments.dropFirst())

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
