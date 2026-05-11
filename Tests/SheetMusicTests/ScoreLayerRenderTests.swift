// swiftlint:disable function_body_length file_length
#if os(macOS)
    import AppKit
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreLayerBuilder bitmap rasterization")
    struct ScoreLayerRenderTests {
        @MainActor
        @Test("Rendered system layer contains non-white pixels where a notehead is expected")
        func renderedTreeHasInk() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register

            let note = Note(pitch: 60, tpc: 14)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let staff = Staff(measures: [m])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])

            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40,
                wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: natW,
            )
            let system = try #require(doc.systems.first)

            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )
            tree.layoutIfNeeded()

            let width = Int(ceil(system.size.width))
            let height = Int(ceil(system.size.height + 1))

            let space = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = width * 4
            let ctx = try #require(CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))

            // White background.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            // ScoreLayerBuilder emits Y-up paths on macOS; combined with
            // CGBitmapContext's top-down buffer rows, a path point at
            // context y=H-77 lands at buffer row ≈ 77.  The per-row byte
            // iteration below already indexes rows from the top, so no
            // context-side flipping is required.
            tree.render(in: ctx)

            let image = try #require(ctx.makeImage())
            let provider = try #require(image.dataProvider)
            let cfData = try #require(provider.data)
            let data = try #require(CFDataGetBytePtr(cfData))

            // Count non-white pixels — the rendered system should have
            // plenty of ink (staff lines + clef + notehead).
            var nonWhite = 0
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let r = data[i], g = data[i + 1], b = data[i + 2]
                if r < 250 || g < 250 || b < 250 {
                    nonWhite += 1
                }
            }
            #expect(
                nonWhite > 100,
                "render produced only \(nonWhite) non-white pixels",
            )

            // Whole-note notehead of middle C sits below the treble staff
            // and after the clef.  Search the chord's rendered origin
            // neighborhood for non-white pixels; the notehead glyph is
            // roughly 1 em wide × 0.5 em tall (em = glyphFontSize).
            let chord = try #require(
                system.measures.first?.elements.first { e in
                    if case .chord = e { return true }
                    return false
                },
            )
            guard case let .chord(notes, _, _, _, _, _, _, _) = chord,
                  let n = notes.first
            else { throw InkAbsenceError.noChordElement }

            let sysBase = CGPoint(
                x: system.measures.first?.origin.x ?? 0,
                y: system.measures.first?.origin.y ?? 0,
            )
            let cx = Int(sysBase.x + n.origin.x)
            let cy = Int(sysBase.y + n.origin.y)
            let em = Int(doc.metrics.glyphFontSize)

            // Search a 1.5em × em box centred on the expected notehead.
            var headInk = 0
            let x0 = max(0, cx - em * 3 / 4)
            let x1 = min(width - 1, cx + em * 3 / 4)
            let y0 = max(0, cy - em / 2)
            let y1 = min(height - 1, cy + em / 2)
            for yy in y0 ... y1 {
                for xx in x0 ... x1 {
                    let i = (yy * width + xx) * 4
                    let r = data[i], g = data[i + 1], b = data[i + 2]
                    if r < 200 || g < 200 || b < 200 {
                        headInk += 1
                    }
                }
            }
            let msg = "notehead region around (\(cx), \(cy)) has only "
                + "\(headInk) dark pixels — notehead is missing"
            #expect(headInk > 30, Comment(rawValue: msg))
        }

        enum InkAbsenceError: Error { case noChordElement }
    }
#endif
