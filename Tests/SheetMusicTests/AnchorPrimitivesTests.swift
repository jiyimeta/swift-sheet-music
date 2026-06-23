#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Anchor primitives")
    struct AnchorPrimitivesTests {
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, *)
        private func twoMeasureDoc() -> LayoutDocument {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(measures: [measure, measure])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )
            return LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
        }

        @Test("anchorReferencePoint resolves measure/tick/staff to a document point")
        func forwardResolves() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let ref = doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            )
            #expect(ref != nil)
            let system = doc.systems[0]
            let measure = try #require(system.measures.first { $0.measureIndex == 1 })
            let expectedX = system.origin.x + measure.origin.x + (measure.tickColumns[0] ?? 0)
            let expectedY = system.origin.y + system.staffOrigins[0].y
            #expect(try abs(#require(ref?.point.x) - expectedX) < 0.001)
            #expect(try abs(#require(ref?.point.y) - expectedY) < 0.001)
            #expect(ref?.sp == doc.metrics.sp)
        }

        @Test("anchorReferencePoint returns nil for an out-of-range measure")
        func forwardNilMeasure() {
            guard #available(macOS 15.0, *) else { return }
            #expect(twoMeasureDoc().anchorReferencePoint(
                measureIndex: 99, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            ) == nil)
        }

        @Test("anchorReferencePoint returns nil for a missing staff")
        func forwardNilStaff() {
            guard #available(macOS 15.0, *) else { return }
            #expect(twoMeasureDoc().anchorReferencePoint(
                measureIndex: 0, tickInMeasure: 0, partIndex: 5, staffIndexInPart: 0,
            ) == nil)
        }
    }
#endif
