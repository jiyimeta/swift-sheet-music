#if os(macOS)
    import AppKit
    import CoreGraphics
    import CoreText
    import Foundation
    import ImageIO
    import SheetMusic
    import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicUI

    /// Draw-program parity probe: how far a renderer that consumes only the `DrawCommand` stream can get from
    /// the Apple renderer, measured in pixels.
    ///
    /// Every non-Apple host — the Kotlin `ScoreCanvas`, the browser `canvas.ts`, and a Windows Direct2D
    /// renderer — draws from `LayoutBridge`'s draw program rather than from `ScoreLayerBuilder`. Whatever the
    /// stream cannot say, those renderers cannot draw. This tool lays a score out ONCE, renders that
    /// `LayoutDocument` through both paths — `ScoreLayerBuilder` (the Apple renderer) and a CoreGraphics walk of
    /// `LayoutBridge.encodePages` — into identically sized bitmaps, and diffs them. Because the layout is shared,
    /// any difference is a renderer difference: a command the stream lacks, a glyph placed by a different rule, a
    /// stroke width clamped on one side.
    ///
    /// The CoreGraphics walk is a port of `canvas.ts` / `ScoreCanvas.kt` (font handling follows the Apple
    /// renderer's own `TextCTFontCache` so the comparison is about the stream, not about synthetic bold), so it
    /// is also the reference for what the Windows renderer has to do — the same walk over Direct2D.
    ///
    /// Driven by environment variables, like the other dev-tool modes:
    ///
    ///   SM_PARITY            — `samples` (every `Samples.catalog` score) or a path to a `.mscz` / `.mscx`
    ///   SM_PARITY_OUT        — output directory (default `tmp/parity`)
    ///   SM_PARITY_WIDTH      — available width in points (default: natural width)
    ///   SM_PARITY_THRESHOLD  — per-pixel max-channel difference that counts as "differing", 0–255 (default 48)
    ///   SM_PARITY_SHIFT      — whole-pixel nudge "dx,dy" applied to the draw-program render (default 0,0)
    ///   SM_PARITY_ONLY       — with `samples`, run just the catalog entry with this name
    ///   SM_PARITY_MAX_MEAN   — exit 1 when the mean differing share (in percent) exceeds this budget
    ///   SM_PARITY_EXPORT     — `1` also writes each score's page as `<name>-page.bin` (a `DrawProgramCodec` payload)
    ///                          and its canvas as `<name>-page.txt` ("widthPx heightPx pxPerMM offsetX offsetY"),
    ///                          which is what the Windows renderer's probe (`windows-render-probe`) draws from
    ///   SM_PARITY_WINDOWS_MAX_MEAN — exit 1 when the Windows renders' mean differing share against the CoreGraphics
    ///                          walk (in percent) exceeds this budget. The same stream through a second rasterizer
    ///                          differs only at anti-aliased edges: 0.007% on the samples (2026-09-30), so 0.1 is
    ///                          a budget a missing or misplaced command blows through.
    ///
    /// Writes `<name>-apple.png`, `<name>-drawprogram.png` and `<name>-diff.png` per score and prints one line per
    /// score plus a summary: the share of pixels that differ, the mean and maximum channel delta. When the output
    /// directory holds a `<name>-windows.png` — the Windows renderer's drawing of the exported page, copied back —
    /// it is diffed against both renders too (`<name>-windows-diff.png` against the CoreGraphics walk).
    ///
    /// Usage:
    ///   SM_PARITY=samples swift run render-previews
    ///   SM_PARITY=~/Documents/foo.mscz SM_PARITY_WIDTH=600 swift run render-previews
    @available(macOS 15.0, *)
    @MainActor
    enum DrawProgramParity {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_PARITY"] != nil
        }

        struct Row {
            let name: String
            let total: Int
            let differing: Int
            let meanDelta: Double
            let maxDelta: Int
            let bestShift: (dx: Int, dy: Int, share: Double)

            var share: Double {
                total == 0 ? 0 : Double(differing) / Double(total)
            }

            var line: String {
                let percent = String(format: "%.3f", share * 100)
                let mean = String(format: "%.2f", meanDelta)
                let shifted = String(format: "%.3f", bestShift.share * 100)
                return "\(name.padding(toLength: 32, withPad: " ", startingAt: 0)) differing \(differing)/\(total)"
                    + " (\(percent)%)  meanΔ \(mean)  maxΔ \(maxDelta)"
                    + "  best shift (\(bestShift.dx), \(bestShift.dy)) → \(shifted)%"
            }
        }

        static func run() throws {
            let env = ProcessInfo.processInfo.environment
            guard let target = env["SM_PARITY"] else { return }
            _ = SheetMusicLayoutApple.install

            let outDir = URL(fileURLWithPath: env["SM_PARITY_OUT"] ?? "tmp/parity", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let threshold = env["SM_PARITY_THRESHOLD"].flatMap { UInt8($0) } ?? 48
            let width = env["SM_PARITY_WIDTH"].flatMap { Double($0) }.map { CGFloat($0) }
            // A whole-pixel nudge applied to the draw-program render, "dx,dy". Used to look at what remains once a
            // systematic offset the shift search reported is taken out — the residual is the renderer difference.
            let nudge: CGPoint = env["SM_PARITY_SHIFT"].map { text in
                let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : .zero
            } ?? .zero
            let only = env["SM_PARITY_ONLY"]

            let subjects: [(name: String, score: Score)]
            if target == "samples" {
                subjects = Samples.catalog.filter { only == nil || $0.name == only }
            } else {
                let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                let data = try Data(contentsOf: url)
                let score = url.pathExtension.lowercased() == "mscx"
                    ? try SheetMusic.loadScore(mscxData: data)
                    : try SheetMusic.loadScore(msczData: data)
                subjects = [(url.deletingPathExtension().lastPathComponent, score)]
            }

            let exports = env["SM_PARITY_EXPORT"] == "1"
            var rows: [Row] = []
            var windowsRows: [(vsWalk: Row, vsApple: Row)] = []
            for (name, score) in subjects {
                let row = try compare(
                    name: name, score: score, width: width, threshold: threshold, nudge: nudge, outDir: outDir,
                    exports: exports,
                )
                rows.append(row)
                print(row.line)
                if let windows = try compareWindows(name: name, threshold: threshold, outDir: outDir) {
                    windowsRows.append(windows)
                    print("  windows vs walk  " + windows.vsWalk.line.dropFirst(32))
                    print("  windows vs apple " + windows.vsApple.line.dropFirst(32))
                }
            }
            reportWindows(windowsRows, budget: env["SM_PARITY_WINDOWS_MAX_MEAN"].flatMap { Double($0) })
            guard !rows.isEmpty else { return }
            let worst = rows.max { $0.share < $1.share }
            let meanShare = rows.reduce(0.0) { $0 + $1.share } / Double(rows.count)
            print("")
            let meanPercent = String(format: "%.3f", meanShare * 100)
            let worstPercent = String(format: "%.3f", (worst?.share ?? 0) * 100)
            print("\(rows.count) scores, threshold \(threshold): mean differing \(meanPercent)%,"
                + " worst \(worst?.name ?? "-") at \(worstPercent)%")
            print("wrote \(outDir.path)")
            // The gate a CI job leans on: a mean above the budget is a non-zero exit, not just a line to read.
            if let budget = env["SM_PARITY_MAX_MEAN"].flatMap({ Double($0) }), meanShare * 100 > budget {
                print("mean differing \(meanPercent)% exceeds SM_PARITY_MAX_MEAN=\(budget)")
                exit(1)
            }
        }

        /// One score: lay out once, render twice, diff.
        static func compare(
            name: String, score: Score, width: CGFloat?, threshold: UInt8, nudge: CGPoint, outDir: URL,
            exports: Bool = false,
        ) throws -> Row {
            // `includeTitleFrame: false` on purpose: `renderDocumentImage` composites systems only (it never draws
            // `TitleFrameView`), and the draw program would draw the title block, so the two would disagree on
            // something that is not a renderer difference. The systems are what this probe is about.
            let options = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: width != nil, includeTitleFrame: false,
            )
            let available = width ?? LayoutEngine.naturalContentWidth(score: score, options: options)
            let document = LayoutEngine.layout(score: score, options: options, availableWidth: available)

            let scale: CGFloat = 2
            let padding: CGFloat = 16
            let apple = try renderDocumentImage(document, scale: scale, padding: padding)

            // The same page assembly the Android reader gets in vertical mode — one page, the document's own
            // size, every command in document millimetres. Only `mode` is read from the wire here; the layout
            // itself is the `document` above, so the two renderers cannot be given different geometry.
            let ptToMM = 25.4 / 72.0
            let pages = LayoutBridge.encodePages(
                document: document, options: .verticalDefault,
                pageWidthMM: Double(document.size.width) * ptToMM,
                pageHeightMM: Double(document.size.height) * ptToMM,
            )
            guard let page = pages.first else { throw RenderError.zeroSize }
            // `renderDocumentImage` rounds the bitmap height UP and anchors its content at the bottom (CoreGraphics
            // Y-up), so the fractional row the `ceil` added sits at the TOP of the Apple render. The draw program
            // is Y-down and anchors at the top, so without this it lands that fraction (< 1 px) higher than the
            // Apple content and every horizontal edge in the diff picks up a sub-pixel smear that is not a renderer
            // difference.
            let ceilRemainder = CGFloat(apple.height) - (document.size.height + 2 * padding) * scale
            let offset = CGPoint(x: padding * scale + nudge.x, y: padding * scale + ceilRemainder + nudge.y)
            let program = try DrawProgramCGRenderer.render(
                page.commands,
                widthPx: apple.width, heightPx: apple.height,
                pxPerMM: scale / ptToMM,
                offsetPx: offset,
            )
            if exports {
                // The same page and the same canvas the walk above drew with, for the Windows renderer to draw.
                try DrawProgramCodec.encode(pages: [page])
                    .write(to: outDir.appendingPathComponent("\(name)-page.bin"))
                try "\(apple.width) \(apple.height) \(Double(scale / ptToMM)) \(Double(offset.x)) \(Double(offset.y))\n"
                    .write(to: outDir.appendingPathComponent("\(name)-page.txt"), atomically: true, encoding: .utf8)
            }

            let result = try BitmapDiff.compare(apple, program, threshold: threshold)
            try writePNG(apple, to: outDir.appendingPathComponent("\(name)-apple.png"))
            try writePNG(program, to: outDir.appendingPathComponent("\(name)-drawprogram.png"))
            try writePNG(result.image, to: outDir.appendingPathComponent("\(name)-diff.png"))
            return Row(
                name: name, total: result.total, differing: result.differing,
                meanDelta: result.meanDelta, maxDelta: result.maxDelta, bestShift: result.bestShift,
            )
        }

        /// The Windows renders' summary, and the gate: exit 1 when their mean differing share against the walk is
        /// above `budget` percent.
        static func reportWindows(_ rows: [(vsWalk: Row, vsApple: Row)], budget: Double?) {
            guard !rows.isEmpty else { return }
            let vsWalk = rows.reduce(0.0) { $0 + $1.vsWalk.share } / Double(rows.count)
            let vsApple = rows.reduce(0.0) { $0 + $1.vsApple.share } / Double(rows.count)
            print("")
            print("windows: \(rows.count) scores, mean differing \(String(format: "%.3f", vsWalk * 100))% "
                + "vs the CoreGraphics walk, \(String(format: "%.3f", vsApple * 100))% vs the Apple renderer")
            if let budget, vsWalk * 100 > budget {
                print("windows mean differing exceeds SM_PARITY_WINDOWS_MAX_MEAN=\(budget)")
                exit(1)
            }
        }

        /// The Windows renderer's `<name>-windows.png`, when there is one, against the CoreGraphics walk (the same
        /// command stream, so the difference is the rasterizer's) and against the Apple renderer (what a user sees on
        /// the Mac). `nil` when the file is absent.
        static func compareWindows(
            name: String, threshold: UInt8, outDir: URL,
        ) throws -> (vsWalk: Row, vsApple: Row)? {
            let windowsURL = outDir.appendingPathComponent("\(name)-windows.png")
            guard FileManager.default.fileExists(atPath: windowsURL.path) else { return nil }
            let windows = try readPNG(windowsURL)
            let walk = try readPNG(outDir.appendingPathComponent("\(name)-drawprogram.png"))
            let apple = try readPNG(outDir.appendingPathComponent("\(name)-apple.png"))
            let vsWalk = try BitmapDiff.compare(walk, windows, threshold: threshold)
            let vsApple = try BitmapDiff.compare(apple, windows, threshold: threshold)
            try writePNG(vsWalk.image, to: outDir.appendingPathComponent("\(name)-windows-diff.png"))
            func row(_ result: BitmapDiff.Result) -> Row {
                Row(
                    name: name, total: result.total, differing: result.differing,
                    meanDelta: result.meanDelta, maxDelta: result.maxDelta, bestShift: result.bestShift,
                )
            }
            return (row(vsWalk), row(vsApple))
        }

        private static func readPNG(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw RenderError.makeImageFailed }
            return image
        }
    }

    @available(macOS 15.0, *)
    extension Samples {
        /// The default sample set, in the order `render-previews` writes them. Shared with `DrawProgramParity` so
        /// the parity probe covers exactly what the preview loop covers.
        static var catalog: [(name: String, score: Score)] {
            [
                ("01-empty", Samples.empty),
                ("02-whole-note", Samples.wholeNote),
                ("03-c-major-scale", Samples.cMajorScale),
                ("04-eighths-beamed", Samples.eighthsBeamed),
                ("05-piano-grand", Samples.pianoGrand),
                ("05b-tall-brace", Samples.tallBrace),
                ("06-accidentals", Samples.accidentals),
                ("07-rests", Samples.rests),
                ("08-key-sigs", Samples.keySignatures),
                ("09-time-sigs", Samples.timeSignatures),
                ("10-dynamics-tempo", Samples.dynamicsTempo),
                ("11-isolated-flags", Samples.isolatedFlags),
                ("12-dotted-durations", Samples.dottedDurations),
                ("13-mixed-beams", Samples.mixedBeams),
                ("14-tuplets", Samples.tuplets),
                ("15-tuplet-bracket", Samples.tupletBracket),
                ("16-beat-boundary", Samples.beatBoundaryBreak),
                ("17-beat-boundary-16ths", Samples.beatBoundary16ths),
                ("18-multi-staff-alignment", Samples.multiStaffAlignment),
                ("19-two-voice-rest-note", Samples.twoVoiceRestNote),
                ("20-multivoice-whole-rest", Samples.multiVoiceWholeRest),
                ("21-rest-note-overlap-repro", Samples.restNoteOverlapRepro),
                ("22-dynamics-low-chord", Samples.dynamicsLowChord),
                ("23-above-staff-overlap", Samples.aboveStaffOverlap),
                ("24-location-system-text", Samples.locationSystemText),
                ("25-harmony-basic", Samples.harmonyBasic),
                ("26-harmony-high-chord", Samples.harmonyHighChord),
                ("27-harmony-high-chord-tied", Samples.harmonyHighChordTied),
                ("28-multi-measure-rest", Samples.multiMeasureRest),
                ("30-rest-tuplet", Samples.restTuplet),
            ]
        }
    }
#endif
