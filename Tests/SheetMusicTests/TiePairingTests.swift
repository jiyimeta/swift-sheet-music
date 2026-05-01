#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Tie pairing")
    struct TiePairingTests {
        @Test("Two quarter notes tied with number 1 produce one TiePair")
        func twoQuartersTied() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let staff = StaffContent(id: 1, measures: [m])
            let score = Score(division: 480, staves: [staff])
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800
            )
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.count == 1)
        }

        @Test("Unmatched tieForward with no tieBack produces no pair")
        func unmatchedTie() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14) // no tieBack
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let staff = StaffContent(id: 1, measures: [m])
            let score = Score(division: 480, staves: [staff])
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800
            )
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.isEmpty)
        }

        @Test("Tie matched across a system break (vertical wrap)")
        func tieAcrossSystemBreak() {
            guard #available(macOS 15.0, *) else { return }
            // Two tied notes in adjacent measures. Force a wrap by making
            // the available width too small to hold both measures so the
            // second one is pushed to a new system. An earlier version
            // discriminated ties by absolute staff-midline Y, which
            // differs across systems and silently dropped these pairs.
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [a])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [b])),
            ])])
            let staff = StaffContent(id: 1, measures: [m1, m2])
            let score = Score(division: 480, staves: [staff])
            let opts = ScoreViewOptions(wrapToViewWidth: true)
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 200
            )
            // Sanity: the wrap actually produced two systems.
            #expect(doc.systems.count == 2)
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.count == 1)
            // The pair endpoints sit in different systems (the from and
            // to absolute Y values land in distinct system bands).
            if let pair = ties.first {
                let fromIdx = LayoutEngine.systemIndex(
                    for: pair.fromOrigin.y, in: doc.systems
                )
                let toIdx = LayoutEngine.systemIndex(
                    for: pair.toOrigin.y, in: doc.systems
                )
                #expect(fromIdx != toIdx)
            }
        }

        @Test("Cross-system tie attaches a half-arc to BOTH systems")
        func crossSystemHalfArcs() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [a])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [b])),
            ])])
            let staff = StaffContent(id: 1, measures: [m1, m2])
            let score = Score(division: 480, staves: [staff])
            let opts = ScoreViewOptions(wrapToViewWidth: true)
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 200
            )
            #expect(doc.systems.count == 2)
            // System 0 carries a half-arc from the chord out to its right
            // edge; system 1 carries the matching half-arc from a point
            // just before the chord up to the chord. Anchoring the END
            // segment at x=0 would cross the synthesised clef + key sig,
            // which is wrong — we anchor it near `firstContentX` instead.
            func tieArcs(in system: LayoutSystem) -> [(from: CGPoint, to: CGPoint)] {
                system.spanners.compactMap { el in
                    if case let .tieArc(f, t, _) = el {
                        return (from: f, to: t)
                    }
                    return nil
                }
            }
            let arcs0 = tieArcs(in: doc.systems[0])
            let arcs1 = tieArcs(in: doc.systems[1])
            #expect(arcs0.count == 1)
            #expect(arcs1.count == 1)
            // BEGIN segment ends near the right edge of system 0.
            if let arc = arcs0.first {
                #expect(arc.to.x >= doc.systems[0].size.width - 4)
            }
            // END segment starts AFTER x=0 (i.e., past the synth header).
            if let arc = arcs1.first {
                #expect(arc.from.x > 0)
            }
        }
    }
#endif
