#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import QuartzCore
    import SheetMusic
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX
    import SheetMusicUI

    // Usage:
    //   swift run render-previews [output-dir]
//
    // Default output dir is `tmp/previews/`. Writes one PNG per sample Score.
    // The tool is macOS 15+ only; it exits cleanly on older OS versions.
//
    // Rendering goes directly through ScoreLayerBuilder + CALayer.render —
    // SwiftUI's ImageRenderer cannot materialise an NSViewRepresentable,
    // so a ScoreView-based path would just emit the yellow "!" placeholder.

    guard #available(macOS 15.0, *) else {
        FileHandle.standardError.write(Data(
            "RenderPreviews requires macOS 15+\n".utf8,
        ))
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
            at: outputDir, withIntermediateDirectories: true,
        )

        _ = SheetMusicLayoutApple.install

        let samples: [(name: String, score: Score)] = [
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
        ]

        for (name, score) in samples {
            let url = outputDir.appendingPathComponent("\(name).png")
            try renderScoreToPNG(score, to: url, scale: 2)
            print("wrote \(url.path)")
        }

        // Multi-measure rest with collapse enabled — separate from the
        // default-options samples loop because the option drives the
        // visual difference.
        let mmRestOpts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            multiMeasureRest: .collapse(minimumMeasures: 2),
        )
        let mmRestURL = outputDir.appendingPathComponent(
            "28b-multi-measure-rest-collapsed.png",
        )
        try renderScoreToPNG(
            Samples.multiMeasureRest, to: mmRestURL, scale: 2,
            options: mmRestOpts,
        )
        print("wrote \(mmRestURL.path)")

        try renderRealWorldCheck(outputDir: outputDir)
    }

    /// Render the real-world test.mscx sample if available.
    @available(macOS 15.0, *)
    @MainActor
    func renderRealWorldCheck(outputDir: URL) throws {
        // Parse Examples/Apple/SheetMusicExample/test.mscx if present and
        // render the first couple of systems. Useful for spot-checking
        // synthesized clefs on staves that rely on MuseScore instrument
        // defaults.
        let examplePath = URL(
            fileURLWithPath:
            "Examples/Apple/SheetMusicExample/test.mscx",
        )
        if FileManager.default.fileExists(atPath: examplePath.path),
           let data = try? Data(contentsOf: examplePath),
           let realScore = try? SheetMusic.loadScore(mscxData: data)
        {
            let trimmed = trimFirstMeasures(of: realScore, count: 2)
            let url = outputDir.appendingPathComponent("90-real-mscx.png")
            try renderScoreToPNG(trimmed, to: url, scale: 2)
            print("wrote \(url.path)")

            // Also render a slice AROUND the drum-groove section (its
            // multi-voice rests are where the note/rest alignment bugs
            // surface).  Measures ~43..44 of test.mscx are the first
            // two-voice drum measures.
            let drumSlice = slicMeasures(of: realScore, from: 42, count: 2)
            let drumURL = outputDir.appendingPathComponent("91-real-drums.png")
            try renderScoreToPNG(drumSlice, to: drumURL, scale: 2)
            print("wrote \(drumURL.path)")
        } else {
            print("skipped 90-real-mscx: Examples/Apple/SheetMusicExample/test.mscx not readable")
        }
    }

    /// Lay out `score` at its natural width and rasterise the resulting
    /// CALayer tree to a PNG. Every system is composited into one bitmap
    /// context with a white background and a small uniform margin.
    @available(macOS 15.0, *)
    @MainActor
    func renderScoreToPNG(
        _ score: Score, to url: URL, scale: CGFloat,
        options: ScoreViewOptions? = nil,
    ) throws {
        let opts = options ?? ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        )
        let naturalWidth = LayoutEngine.naturalContentWidth(
            score: score, options: opts,
        )
        let doc = LayoutEngine.layout(
            score: score, options: opts,
            availableWidth: naturalWidth,
        )

        let padding: CGFloat = 16
        let pxW = Int(ceil((doc.size.width + 2 * padding) * scale))
        let pxH = Int(ceil((doc.size.height + 2 * padding) * scale))
        guard pxW > 0, pxH > 0 else { throw RenderError.zeroSize }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW, height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )
        else { throw RenderError.contextInitFailed }

        // Work in point coordinates; `scale` maps points → pixels.
        ctx.scaleBy(x: scale, y: scale)

        // White background.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(
            x: 0,
            y: 0,
            width: doc.size.width + 2 * padding,
            height: doc.size.height + 2 * padding,
        ))

        // ScoreLayerBuilder emits Y-up paths (AppKit NSView convention on
        // macOS). Combined with CGBitmapContext's top-down row buffer,
        // a tree-internal point at y=sys.size.height (visually the top)
        // lands at bitmap row 0 of that tree's region. Stacking systems
        // therefore means placing each tree's bottom edge at bitmap row
        // = sys.origin.y + sys.size.height.
        for sys in doc.systems {
            let tree = ScoreLayerBuilder.buildSystem(
                sys, metrics: doc.metrics,
            )
            tree.layoutIfNeeded()
            ctx.saveGState()
            let ty = doc.size.height + 2 * padding
                - padding - sys.origin.y - sys.size.height
            ctx.translateBy(x: sys.origin.x + padding, y: ty)
            tree.render(in: ctx)
            ctx.restoreGState()
        }

        guard let cg = ctx.makeImage() else {
            throw RenderError.makeImageFailed
        }
        try writePNG(cg, to: url)
    }

    enum RenderError: Error {
        case zeroSize
        case contextInitFailed
        case makeImageFailed
        case pngEncodeFailed
    }

    /// Keep the first `count` measures of every staff so a large real-world
    /// score renders into a reasonable canvas.
    @available(macOS 15.0, *)
    func trimFirstMeasures(of score: Score, count: Int) -> Score {
        var s = score
        for p in s.parts.indices {
            for st in s.parts[p].staves.indices {
                s.parts[p].staves[st].measures =
                    Array(s.parts[p].staves[st].measures.prefix(count))
            }
        }
        return s
    }

    /// Keep an arbitrary contiguous measure range from every staff.
    @available(macOS 15.0, *)
    func slicMeasures(of score: Score, from start: Int, count: Int) -> Score {
        var s = score
        for p in s.parts.indices {
            for st in s.parts[p].staves.indices {
                let measures = s.parts[p].staves[st].measures
                let clamped = max(0, min(start, measures.count))
                let end = min(start + count, measures.count)
                s.parts[p].staves[st].measures = Array(measures[clamped ..< end])
            }
        }
        return s
    }

    @available(macOS 15.0, *)
    func writePNG(_ cg: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:])
        else { throw RenderError.pngEncodeFailed }
        try data.write(to: url)
    }

    if #available(macOS 15.0, *) {
        try MainActor.assumeIsolated { try run() }
    }
#endif
