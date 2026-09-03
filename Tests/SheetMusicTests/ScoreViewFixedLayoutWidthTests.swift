#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    @Suite("ScoreView fixedLayoutWidth")
    struct ScoreViewFixedLayoutWidthTests {
        private let _installApple = TestSupport.installApple

        /// 20 quarter-note measures: enough to wrap several times at
        /// 400 pt and fewer times at 800, so a width that is honored
        /// is visible in the document, not just in a variable.
        private static func wrappingScore() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            var measures: [Measure] = []
            for _ in 0 ..< 20 {
                measures.append(Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [note])),
                    .chord(Chord(duration: .quarter, notes: [note])),
                    .chord(Chord(duration: .quarter, notes: [note])),
                    .chord(Chord(duration: .quarter, notes: [note])),
                ])]))
            }
            let staff = Staff(measures: measures)
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                )],
            )
        }

        // MARK: - The width seam

        @Test("fixedLayoutWidth outranks the caller's availableWidth")
        func fixedBeatsExplicit() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions(fixedLayoutWidth: 800)
            #expect(ScoreView.resolvedWrapWidth(
                options: opts, explicitWidth: 400,
            ) == 800)
        }

        @Test("without fixedLayoutWidth the caller's width is used")
        func explicitUsedWhenNoFixed() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions()
            #expect(ScoreView.resolvedWrapWidth(
                options: opts, explicitWidth: 400,
            ) == 400)
        }

        @Test("nil + nil means measure the container")
        func nilWhenNeitherIsSet() {
            guard #available(macOS 15.0, *) else { return }
            #expect(ScoreView.resolvedWrapWidth(
                options: ScoreViewOptions(), explicitWidth: nil,
            ) == nil)
        }

        @Test("the staffSize * 4 floor applies to both sources")
        func floorApplies() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions(
                staffSize: 28, fixedLayoutWidth: 10,
            )
            #expect(ScoreView.resolvedWrapWidth(
                options: opts, explicitWidth: nil,
            ) == 112)
            #expect(ScoreView.resolvedWrapWidth(
                options: ScoreViewOptions(staffSize: 28),
                explicitWidth: 10,
            ) == 112)
            #expect(ScoreView.flooredWrapWidth(
                10, options: ScoreViewOptions(staffSize: 28),
            ) == 112)
            #expect(ScoreView.flooredWrapWidth(
                900, options: ScoreViewOptions(staffSize: 28),
            ) == 900)
        }

        @Test("fixedLayoutWidth is ignored in horizontal mode")
        func ignoredWhenNotWrapping() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions(
                wrapToViewWidth: false, fixedLayoutWidth: 800,
            )
            #expect(ScoreView.resolvedWrapWidth(
                options: opts, explicitWidth: 400,
            ) == nil)
        }

        // MARK: - End to end through the rendered view

        /// The vertical stack ends in `.frame(width: doc.size.width)`,
        /// so the rendered image's width IS the document width the
        /// view chose. Rendering the same score with two different
        /// container widths and one fixed layout width must therefore
        /// produce the same image width — and it must be the width
        /// the engine produces at 800, not at 400 or 1200.
        @MainActor
        @Test("the rendered width follows the option, not the container")
        func renderedWidthFollowsTheOption() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.wrappingScore()
            let fixed = ScoreViewOptions(fixedLayoutWidth: 800)
            let expected = LayoutEngine.layout(
                score: score, options: fixed, availableWidth: 800,
            ).size.width

            for container in [CGFloat(600), CGFloat(1200)] {
                let view = ScoreView(
                    score: score,
                    options: fixed,
                    availableWidth: container,
                )
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                #expect(
                    abs(CGFloat(image.width) - expected) <= 2,
                    "container \(container) rendered \(image.width) pt wide, expected \(expected)",
                )
            }
        }

        /// The control for the test above: with the option off, the
        /// same two containers DO produce different widths. Without
        /// this, a view that ignored `availableWidth` entirely would
        /// pass `renderedWidthFollowsTheOption`.
        @MainActor
        @Test("without the option the rendered width follows the container")
        func withoutTheOptionWidthFollowsTheContainer() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.wrappingScore()
            let plain = ScoreViewOptions()
            var widths: [Int] = []
            for container in [CGFloat(600), CGFloat(1200)] {
                let view = ScoreView(
                    score: score, options: plain,
                    availableWidth: container,
                )
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                widths.append(image.width)
            }
            #expect(widths[0] != widths[1])
        }
    }
#endif
