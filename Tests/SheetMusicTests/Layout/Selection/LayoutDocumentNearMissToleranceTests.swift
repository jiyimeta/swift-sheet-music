#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The near-miss rescue's two questions: WHICH element a miss lands on, and HOW FAR a miss may be.
    ///
    /// Split from `LayoutDocumentEditingHitTestTests`, which owns the ladder itself — the rungs, the on-staff gate
    /// and the active-voice preference. These are about the rescue that runs when the ladder says nothing, and they
    /// need a fixture of their own: chords with nothing between them, so a probe can sit in open space with one note
    /// on each side.
    @Suite("LayoutDocument near-miss tolerance")
    struct LayoutDocumentNearMissToleranceTests {
        private let _installApple = TestSupport.installApple

        /// One voice of three quarter chords, nothing else in the bar. No rest between them, so the only things a
        /// probe can resolve to are the chords themselves.
        private func threeChordSample() -> Score {
            let chord = { (p: Int) -> VoiceElement in
                .chord(Chord(duration: .quarter, notes: [Note(pitch: p, tpc: 14)]))
            }
            let measure = Measure(voices: [
                Voice(elements: [.clef(Clef(concertClefType: "G")), chord(60), chord(64), chord(65)]),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(
                        staffType: "stdNormal",
                        group: "pitched",
                        defaultClefType: "G",
                        measures: [measure],
                    )],
                )],
            )
        }

        private func layout(_ score: Score, staffSize: CGFloat = 28) -> LayoutDocument {
            var options = ScoreViewOptions()
            options.staffSize = staffSize
            return LayoutEngine.layout(score: score, options: options, availableWidth: 600)
        }

        /// Every notehead anchor in document order, with its id — enough to place a probe BETWEEN two of them.
        private func chordAnchors(in document: LayoutDocument) -> [(point: CGPoint, id: NoteID)] {
            guard let system = document.systems.first else { return [] }
            var anchors: [(point: CGPoint, id: NoteID)] = []
            for measure in system.measures {
                let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                for el in measure.elements {
                    guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el, let n = notes.first
                    else { continue }
                    let mirrorDx = n.mirrorDx(stem: stem, sp: system.sp)
                    anchors.append((CGPoint(x: base.x + n.origin.x + mirrorDx, y: base.y + n.origin.y), n.noteID))
                }
            }
            return anchors
        }

        /// The rescue answers with the CLOSEST element, not the first one the walk happens to visit.
        ///
        /// Until 2026-09-12 it took `itemIDs(in:)`'s first result, which is document order, so a click that fell
        /// between two notes always resolved to the one on its LEFT no matter how much closer the one on its right
        /// was. The user's report was exactly that shape: a click in open space selected "the note just to the
        /// left".
        @Test("A near miss between two notes rescues to the closer one, not the earlier one")
        func nearMissPrefersTheCloserNote() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(threeChordSample())
            let tester = ScoreHitTester(document: doc)
            let anchors = chordAnchors(in: doc)
            try #require(anchors.count >= 2)
            let left = anchors[anchors.count - 2]
            let right = anchors[anchors.count - 1]

            // Three quarters of the way from the left note to the right one: unambiguously nearer the right one.
            let gap = right.point.x - left.point.x
            let probe = CGPoint(x: left.point.x + gap * 0.75, y: (left.point.y + right.point.y) / 2)
            #expect(tester.hitTest(at: probe) == nil, "a rescue case, not an on-target hit")

            // A tolerance wide enough to reach BOTH — otherwise this would pass for the trivial reason that only
            // one candidate exists, which the retired document-order rule managed too.
            let reachable = tester.itemIDs(near: probe, within: gap)
            #expect(reachable.contains(.note(left.id)))
            #expect(reachable.contains(.note(right.id)))

            #expect(doc.editingHitTest(at: probe, activeVoice: 0, nearMissTolerance: gap) == .note(right.id))
        }

        /// A pointer-driven host passes its own, much smaller, tolerance — and then a click in open staff space
        /// must NOT be rescued to a note several staff spaces away. What that click means is the host's to decide
        /// (Folino selects the bar); the engine's job is to stop claiming it was a near miss.
        @Test("A tolerance smaller than the miss refuses a rescue the fingertip default would have made")
        func tighterToleranceRefusesADistantRescue() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(threeChordSample())
            let tester = ScoreHitTester(document: doc)
            let sp = try #require(doc.systems.first).sp
            let last = try #require(chordAnchors(in: doc).last)

            // Two staff spaces clear of the notehead's own target, straight out along the staff.
            let probe = CGPoint(x: last.point.x + sp * 3.2, y: last.point.y)
            #expect(tester.hitTest(at: probe) == nil, "a rescue case, not an on-target hit")

            #expect(doc.editingHitTest(at: probe, activeVoice: 0) == .note(last.id))
            #expect(doc.editingHitTest(at: probe, activeVoice: 0, nearMissTolerance: sp * 0.5) == nil)
        }
    }
#endif
