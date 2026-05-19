#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Spanner segmentation")
    struct SpannerSegmentationTests {
        private let _installApple = TestSupport.installApple

        @Test("Slur spanning two measures produces one anchor")
        func slurAnchor() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let slur = Spanner(
                kind: .slur, rawType: "Slur", nextMeasuresOffset: 1,
            )
            let m1 = Measure(voices: [Voice(elements: [
                .spanner(slur),
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let staff = Staff(measures: [m1, m2])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let anchors = LayoutEngine.collectSpanners(score: score)
            #expect(anchors.count == 1)
            // `<measures>1</measures>` with no fractional remainder
            // resolves to the right-edge sentinel: endMeasure = startIdx
            // + 1 - 1 = 0, endTick = 0 (which `attachSpanners` reads
            // as "right edge of that measure"). Visually equivalent to
            // "start of measure 1".
            #expect(anchors.first?.endMeasure == 0)
            #expect(anchors.first?.endTick == 0)
        }

        @Test("Volta with endings is preserved in the anchor")
        func voltaEndings() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let v1 = Spanner(
                kind: .volta, rawType: "Volta",
                nextMeasuresOffset: 0,
                voltaEndings: [1],
            )
            let m = Measure(voices: [Voice(elements: [
                .spanner(v1),
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let staff = Staff(measures: [m])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let anchors = LayoutEngine.collectSpanners(score: score)
            #expect(anchors.first?.voltaEndings == [1])
        }

        @Test("Partial-measure ottava starts at the begin chord, not the measure left edge")
        func partialMeasureOttavaStartsAtChord() {
            guard #available(macOS 15.0, *) else { return }
            // 4/4 measure: 5 eighths (= 5/8) followed by an ottava
            // 8va that covers only the dotted-quarter chord at the
            // end of the measure (3/8). Mirrors the begin-side
            // spanner MuseScore writes between the half-cadence rest
            // and the final chord.
            let note = Note(pitch: 60, tpc: 14)
            let division = 480
            var elements: [VoiceElement] = []
            for _ in 0 ..< 5 {
                elements.append(.chord(Chord(
                    duration: .eighth, notes: [note],
                )))
            }
            let ottava = Spanner(
                kind: .ottava, rawType: "Ottava",
                nextMeasuresOffset: 0,
                nextFractionsOffset: Fraction(numerator: 3, denominator: 8),
            )
            elements.append(.spanner(ottava))
            elements.append(.chord(Chord(
                duration: .quarter.dotted(1), notes: [note],
            )))
            let m = Measure(voices: [Voice(elements: elements)])
            let staff = Staff(measures: [m])
            let score = Score(division: division, parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                ),
            ])

            let anchor = LayoutEngine.collectSpanners(score: score)
                .first
            #expect(anchor?.startTick == 5 * (division / 2))
            // 5 eighths + dotted quarter lands exactly on the
            // measure's right barline → resolved to the right-edge
            // sentinel (`endTick == 0`) rather than `mTicks`.
            #expect(anchor?.endTick == 0)
            #expect(anchor?.endMeasure == 0)

            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let system = doc.systems.first
            let measure = system?.measures.first
            // Ottava segment is the only attached spanner.
            let ottavaSegment = system?.spanners.first { el in
                if case .spannerSegment(.ottava, _, _, _, _, _) = el {
                    return true
                }
                return false
            }
            guard case let .spannerSegment(_, fromOrigin, _, _, _, _) =
                ottavaSegment, let m = measure
            else {
                Issue.record("expected ottava segment in system")
                return
            }
            // The segment must start at the dotted-quarter chord's
            // x — well past the measure's left edge. tickColumns
            // for tick 5*(div/2) records the chord's measure-local x.
            let expectedLocalX = m.tickColumns[5 * (division / 2)]
            #expect(expectedLocalX != nil)
            if let localX = expectedLocalX {
                let expected = m.origin.x + localX
                #expect(abs(fromOrigin.x - expected) < 0.001)
                // Sanity: the chord X is well past the measure's
                // left edge (which is what the old code used).
                #expect(fromOrigin.x > m.origin.x + 20)
            }
        }

        /// Builds a 3-staff score whose third staff carries an 8va
        /// covering its single quarter chord. Used by the
        /// own-staff-anchoring test.
        private static func threeStaffOttavaScore() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let plain = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let ottava = Spanner(
                kind: .ottava, rawType: "Ottava",
                nextMeasuresOffset: 0,
                nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            )
            let mBot = Measure(voices: [Voice(elements: [
                .spanner(ottava),
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            func part(_ id: String, _ measure: Measure) -> Part {
                Part(
                    id: id,
                    instrument: Instrument(id: id),
                    staves: [Staff(measures: [measure])],
                )
            }
            return Score(division: 480, parts: [
                part("1", plain), part("2", plain), part("3", mBot),
            ])
        }

        @Test("Ottava on a non-top staff anchors above its own staff, not the top staff")
        func ottavaAnchorsToOwnStaff() {
            guard #available(macOS 15.0, *) else { return }
            // The 8va belongs to flat staff index 2. Mirrors the
            // idea8 case where an 8va on the third treble staff was
            // anchored above the top staff because `anchorY` ignored
            // `startStaff`.
            let score = Self.threeStaffOttavaScore()
            let anchor = LayoutEngine.collectSpanners(score: score).first
            #expect(anchor?.startStaff == 2)

            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            guard let system = doc.systems.first else {
                Issue.record("expected at least one system")
                return
            }
            let ottavaSegment = system.spanners.first { el in
                if case .spannerSegment(.ottava, _, _, _, _, _) = el {
                    return true
                }
                return false
            }
            guard case let .spannerSegment(_, fromOrigin, _, _, _, _) =
                ottavaSegment
            else {
                Issue.record("expected ottava segment")
                return
            }
            // Anchored above the third staff, not the first.
            let topStaffOriginY = system.staffOrigins[0].y
            let ownStaffOriginY = system.staffOrigins[2].y
            #expect(ownStaffOriginY > topStaffOriginY)
            // The segment Y should be above the OWN staff's top, not
            // the system top — i.e. closer to ownStaffOriginY than to
            // topStaffOriginY.
            let distToOwn = abs(fromOrigin.y - ownStaffOriginY)
            let distToTop = abs(fromOrigin.y - topStaffOriginY)
            #expect(distToOwn < distToTop)
        }
    }
#endif
