#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    @Suite("ScoreView rendering smoke")
    struct ScoreViewRenderTests {
        private let _installApple = TestSupport.installApple

        @MainActor
        @Test("ScoreView renders a minimal score to a non-empty CGImage")
        func rendersMinimalScore() throws {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let staff = Staff(measures: [m])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let view = ScoreView(score: score)
                .frame(width: 600, height: 200)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = renderer.cgImage
            try #require(image != nil)
            #expect((image?.width ?? 0) > 0)
            #expect((image?.height ?? 0) > 0)
        }

        @Test("Layout height grows with staffSize (vertical mode)")
        func layoutHeightGrowsWithStaffSize() {
            guard #available(macOS 15.0, *) else { return }
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
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])

            var prevH: CGFloat = 0
            for size: CGFloat in [8, 14, 20, 26, 32] {
                let opts = ScoreViewOptions(
                    staffSize: size, systemGap: size * 0.85,
                    wrapToViewWidth: true,
                )
                let doc = LayoutEngine.layout(
                    score: score, options: opts,
                    availableWidth: 377,
                )
                #expect(
                    doc.size.height > prevH,
                    "staffSize=\(size): height \(doc.size.height) should exceed \(prevH)",
                )
                prevH = doc.size.height
            }
        }

        @Test("Layout width grows with staffSize (horizontal mode)")
        func layoutWidthGrowsWithStaffSize() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            var measures: [Measure] = []
            for _ in 0 ..< 10 {
                measures.append(Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [note])),
                    .chord(Chord(duration: .quarter, notes: [note])),
                ])]))
            }
            let staff = Staff(measures: measures)
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])

            var prevW: CGFloat = 0
            for size: CGFloat in [8, 14, 20, 26, 32] {
                let opts = ScoreViewOptions(
                    staffSize: size, systemGap: size * 0.85,
                    wrapToViewWidth: false,
                )
                let natW = LayoutEngine.naturalContentWidth(
                    score: score, options: opts,
                )
                let doc = LayoutEngine.layout(
                    score: score, options: opts,
                    availableWidth: natW,
                )
                #expect(
                    doc.size.width > prevW,
                    "staffSize=\(size): width \(doc.size.width) should exceed \(prevW)",
                )
                prevW = doc.size.width
            }
        }
    }
#endif
