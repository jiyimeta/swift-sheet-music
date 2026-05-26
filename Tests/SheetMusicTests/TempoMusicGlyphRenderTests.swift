#if os(macOS)
    import AppKit
    import CoreGraphics
    import CoreText
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import Testing

    /// Regression guard for the CALayer renderer rendering a tempo
    /// indication's leading SMuFL metronome glyph (e.g.
    /// `<sym>metNoteQuarterUp</sym>`, synthesised as the PUA codepoint
    /// U+E1D5) as a tofu / "?" box because it drew the whole string with
    /// the Edwin text font instead of switching to Bravura for the music
    /// run. The Edwin/system font has no glyph in the SMuFL Private Use
    /// Area, and process-registered fonts are not in CoreText's automatic
    /// fallback cascade, so the glyph must be selected explicitly.
    @Suite("Tempo metronome glyph uses Bravura in the CALayer renderer")
    struct TempoMusicGlyphRenderTests {
        private let _installApple = TestSupport.installApple

        @MainActor
        @Test("Tempo text mark renders its metronome glyph with Bravura, not the text font")
        // swiftlint:disable:next function_body_length
        func tempoGlyphRendersWithBravura() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register

            // One measure (whole rest) carrying a 120 BPM tempo at the
            // downbeat. 2.0 beats/sec = 120 BPM, so the layout engine
            // synthesises "\u{E1D5} = 120".
            let measure = Measure(voices: [Voice(elements: [
                .rest(duration: .whole),
            ])])
            let staff = Staff(measures: [measure])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                )],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .tempo(Tempo(beatsPerSecond: 2.0)),
                    ),
                ])],
            )

            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
            let system = try #require(doc.systems.first)

            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )
            tree.layoutIfNeeded()

            // Reference: Bravura's tight path bbox for the metronome
            // quarter note (U+E1D5) at the resolved tempo point size.
            let pointSize = ResolvedTextStyle.resolve(
                .tempo, metrics: doc.metrics,
            ).pointSize
            let bravura = CTFontCreateWithName(
                BravuraFont.familyName as CFString, pointSize, nil,
            )
            let refBox = try #require(
                Self.glyphBoundingBox(font: bravura, scalar: 0xE1D5),
            )
            // Sanity: confirm Bravura actually resolved (not a fallback).
            // A quarter note is clearly taller than it is wide.
            try #require(refBox.height > refBox.width)

            // The rendered tree must contain a shape layer whose path
            // bbox matches that glyph (translation + Y-flip preserve
            // width & height). With the bug the glyph is buried inside a
            // single wide Edwin text layer for the whole "= 120" string,
            // so no layer matches.
            var boxes: [CGRect] = []
            Self.collectShapeBoxes(tree, into: &boxes)

            let tol: CGFloat = 1.5
            let glyphBoxes = boxes.filter { box in
                abs(box.width - refBox.width) < tol
                    && abs(box.height - refBox.height) < tol
            }
            let note = try #require(
                glyphBoxes.first,
                Comment(
                    rawValue: "no rendered path matches Bravura's "
                        + "metronome glyph bbox \(refBox.size) — the tempo "
                        + "glyph was drawn with the text font",
                ),
            )

            // The "= 120" text sits to the right of the note and
            // overlaps it vertically. (Relative comparisons are valid in
            // the platform's flipped coords since both boxes share it.)
            let textBox = try #require(
                boxes
                    .filter { box in
                        box.minX > note.minX
                            && box.maxY > note.minY && box.minY < note.maxY
                    }
                    .min(by: { $0.minX < $1.minX }),
                "could not locate the tempo's text run layer",
            )

            // X regression: a real gap separates the note from the text.
            // Ink-left anchoring drops the leading space (no ink), which
            // butts "=" straight against the note; the fix re-adds it.
            #expect(
                textBox.minX > note.maxX,
                Comment(
                    rawValue: "tempo text (minX \(textBox.minX)) "
                        + "overlaps the metronome glyph (maxX \(note.maxX)) "
                        + "— the separating space was dropped",
                ),
            )

            // Y regression: the whole note straddles the text's vertical
            // centre rather than resting its head on the baseline with
            // the stem poking above (font-metric centring did the latter).
            let centreDelta = abs(note.midY - textBox.midY)
            #expect(
                centreDelta < doc.metrics.sp,
                Comment(
                    rawValue: "metronome glyph centre is "
                        + "\(centreDelta) pt from the text centre — the whole "
                        + "note is not vertically centred",
                ),
            )
        }

        private static func glyphBoundingBox(
            font: CTFont, scalar: UInt32,
        ) -> CGRect? {
            guard let unicode = UnicodeScalar(scalar) else { return nil }
            let utf16 = Array(String(unicode).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(
                font, utf16, &glyphs, utf16.count,
            ), let glyph = glyphs.first,
            let path = CTFontCreatePathForGlyph(font, glyph, nil)
            else { return nil }
            return path.boundingBoxOfPath
        }

        @MainActor
        private static func collectShapeBoxes(
            _ layer: CALayer, into boxes: inout [CGRect],
        ) {
            if let shape = layer as? CAShapeLayer, let path = shape.path {
                let box = path.boundingBoxOfPath
                if !box.isNull, !box.isEmpty { boxes.append(box) }
            }
            for sub in layer.sublayers ?? [] {
                collectShapeBoxes(sub, into: &boxes)
            }
        }
    }
#endif
