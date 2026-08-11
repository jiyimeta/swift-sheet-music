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

    /// Routes to a single-purpose dev-tool mode when its trigger env var
    /// is set. Returns `true` when a tool ran, so the caller can return
    /// immediately instead of falling into the default sample-render loop.
    @available(macOS 15.0, *)
    @MainActor
    func routeToDevTool() throws -> Bool {
        // Corpus annotation-collision detector (SM_COLLIDE_DIR=… swift run
        // render-previews), the BEFORE/AFTER measurement tool for the
        // skyline autoplace pass.
        if CollisionReport.isRequested {
            try CollisionReport.run()
            return true
        }
        // Ad-hoc single-score render (SM_SCORE=… swift run render-previews),
        // used to eyeball layout against MuseScore's own PDF output.
        if AdHocRender.isRequested {
            try AdHocRender.run()
            return true
        }
        // Corpus batch render (SM_RENDER_DIR=… swift run render-previews),
        // the BEFORE/AFTER pixel gate for layout refactors.
        if CorpusRender.isRequested {
            try CorpusRender.run()
            return true
        }
        return false
    }

    @available(macOS 15.0, *)
    @MainActor
    func run() throws {
        if try routeToDevTool() { return }
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

        try renderOptionDrivenSamples(outputDir: outputDir)
        try renderRealWorldCheck(outputDir: outputDir)
        try renderBreathFixture(outputDir: outputDir)
    }

    /// Samples that live outside the default-options loop because a
    /// non-default `ScoreViewOptions` value is exactly what they exist
    /// to show.
    @available(macOS 15.0, *)
    @MainActor
    func renderOptionDrivenSamples(outputDir: URL) throws {
        // Multi-measure rest with collapse enabled.
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

        // Hidden elements at 50 % opacity. This is the ONLY rasterized
        // coverage of `ScoreLayerBuilder.drawInvisibleElements`, the
        // shared system-level layer that hidden elements composite into
        // (see `Samples.hiddenElements`).
        let invisibleOpts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            showsInvisibleElements: true,
        )
        let invisibleURL = outputDir.appendingPathComponent(
            "29-hidden-elements.png",
        )
        try renderScoreToPNG(
            Samples.hiddenElements, to: invisibleURL, scale: 2,
            options: invisibleOpts,
        )
        print("wrote \(invisibleURL.path)")
    }

    /// Render the unpacked `test_breath.mscx` fixture if present.
    /// Used by the controller to iterate on layout constants for the
    /// breath / caesura placement against the MuseScore reference.
    @available(macOS 15.0, *)
    @MainActor
    func renderBreathFixture(outputDir: URL) throws {
        let path = "/tmp/test_breath_unpacked/test_breath.mscx"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let score = try? SheetMusic.loadScore(mscxData: data)
        else {
            print("skipped 99-breath-fixture: \(path) not present")
            return
        }
        let url = outputDir.appendingPathComponent("99-breath-fixture.png")
        try renderScoreToPNG(score, to: url, scale: 2)
        print("wrote \(url.path)")
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
        availableWidth: CGFloat? = nil,
    ) throws {
        let opts = options ?? ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        )
        let naturalWidth = availableWidth ?? LayoutEngine.naturalContentWidth(
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
