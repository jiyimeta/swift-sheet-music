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

        @Test("resolveAnchor recovers a clean anchor at a tick column")
        func inverseAtColumn() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let ref = try #require(doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            ))
            let r = doc.resolveAnchor(at: ref.point)
            #expect(r != nil)
            #expect(r?.measureIndex == 1)
            #expect(r?.tickInMeasure == 0)
            #expect(r?.partIndex == 0)
            #expect(r?.staffIndexInPart == 0)
            #expect(try abs(#require(r?.dxSp)) < 0.001)
            #expect(try abs(#require(r?.verticalOffsetSp)) < 0.001)
        }

        @Test("forward(resolve(point)) + offsets recovers the point (round-trip)")
        func roundTrip() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let sp = doc.metrics.sp
            // Points built as known reference points plus an sp-sized offset (including above-staff, -2 sp).
            let cases: [(Int, Int, CGFloat, CGFloat)] = [(0, 0, 0, 0), (1, 0, 1.5, -2.0)]
            for (mi, tick, dx, vy) in cases {
                let ref = try #require(doc.anchorReferencePoint(
                    measureIndex: mi, tickInMeasure: tick, partIndex: 0, staffIndexInPart: 0,
                ))
                let p = CGPoint(x: ref.point.x + dx * sp, y: ref.point.y + vy * sp)
                let r = try #require(doc.resolveAnchor(at: p))
                let ref2 = try #require(doc.anchorReferencePoint(
                    measureIndex: r.measureIndex, tickInMeasure: r.tickInMeasure,
                    partIndex: r.partIndex, staffIndexInPart: r.staffIndexInPart,
                ))
                let recovered = CGPoint(
                    x: ref2.point.x + r.dxSp * sp,
                    y: ref2.point.y + r.verticalOffsetSp * sp,
                )
                #expect(abs(recovered.x - p.x) < 0.01)
                #expect(abs(recovered.y - p.y) < 0.01)
            }
        }

        @Test("resolveAnchor returns nil for an empty document")
        func inverseNilEmpty() {
            guard #available(macOS 15.0, *) else { return }
            let empty = LayoutEngine.layout(score: Score(division: 480), options: .init(), availableWidth: 800)
            #expect(empty.resolveAnchor(at: .zero) == nil)
        }
    }
#endif
