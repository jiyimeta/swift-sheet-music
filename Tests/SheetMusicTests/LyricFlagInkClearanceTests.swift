#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Lyric placement flag ink clearance")
    @MainActor
    struct LyricFlagInkClearanceTests {
        private let _installApple = TestSupport.installApple

        /// The CALayer renderer is an independent endpoint/flag oracle. Inverting the
        /// stem endpoint or dropping lyric-only stem reservation must fail this test.
        @Test(arguments: [Placement.above, .below])
        func lyricClearsRenderedStemAndFlag(side: Placement) throws {
            guard #available(macOS 15.0, *) else { return }
            var lyric = Lyric(text: "Ag")
            lyric.elementProperties.placement = side
            let pitches = side == .above ? [48, 50, 79] : [62, 79, 81]
            let chord = Chord(
                duration: .eighth,
                notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) }),
                lyrics: [lyric],
            )
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
                )],
            )
            let document = TextPlacementFixtures.layout(score)
            let elements = document.systems.flatMap(\.measures).flatMap(\.elements)
            let chordElement = try #require(elements.first { if case .chord = $0 { true } else { false } })
            let lyricElement = try #require(elements.first { $0.textPlacement?.verse == 0 })
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                chordElement,
                base: .zero,
                metrics: document.metrics,
                height: 1000,
                context: &context,
                into: parent,
            )
            let paths = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            #expect(paths.count >= 5)
            var ink = CGRect.null
            for layer in paths {
                let path = try #require(layer.path)
                let painted = layer.fillColor != nil ? path : path.copy(
                    strokingWithWidth: layer.lineWidth,
                    lineCap: .butt,
                    lineJoin: .miter,
                    miterLimit: 10,
                )
                let box = painted.boundingBoxOfPath
                ink = ink.union(CGRect(x: box.minX, y: 1000 - box.maxY, width: box.width, height: box.height))
            }
            let text = try #require(TextInkGeometry.rects(for: lyricElement, metrics: document.metrics)?.first)
            if side == .above {
                #expect(ink.minY - text.maxY >= 1.75 - 0.001)
            } else {
                #expect(text.minY - ink.maxY >= 1.75 - 0.001)
            }
        }

        @Test func oldElementPropertiesCodableAcceptsMissingAutoplace() throws {
            let old = Data("{\"visible\":true}".utf8)
            #expect(try JSONDecoder().decode(ElementProperties.self, from: old).autoplace == nil)
            let value = ElementProperties(autoplace: false)
            #expect(try JSONDecoder().decode(ElementProperties.self, from: JSONEncoder().encode(value)) == value)
        }
    }
#endif
