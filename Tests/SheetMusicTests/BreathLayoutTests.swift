#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutEngine breath/caesura placement")
    struct BreathLayoutTests {
        private let _installApple = TestSupport.installApple

        /// One measure: `[chord(C4), breath, chord(D4)]`. The canonical
        /// MSCX shape for a breath mark between two chords.
        private static func breathBetweenChordsScore(
            kind: Breath.Kind = .breathMark(.comma),
            visible: Bool = true,
        ) -> Score {
            let cChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            )
            let dChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
            )
            let breath = Breath(kind: kind, visible: visible)
            let voice = Voice(elements: [
                .chord(cChord),
                .breath(breath),
                .chord(dChord),
            ])
            let measure = Measure(voices: [voice])
            let staff = Staff(measures: [measure])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                )],
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func laidOut(
            _ s: Score,
            showsInvisibleElements: Bool = false,
        ) -> LayoutDocument {
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
                showsInvisibleElements: showsInvisibleElements,
            )
            let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
            return LayoutEngine.layout(
                score: s, options: opts, availableWidth: natW,
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func collectBreathsAndChords(
            _ doc: LayoutDocument,
        ) -> (breaths: [(Breath.Kind, CGPoint, Bool)], chordXs: [CGFloat]) {
            var breaths: [(Breath.Kind, CGPoint, Bool)] = []
            var chordXs: [CGFloat] = []
            for system in doc.systems {
                for measure in system.measures {
                    let combined = measure.elements + measure.invisibleElements
                    for el in combined {
                        switch el {
                        case let .breath(kind, origin, visible):
                            breaths.append((kind, origin, visible))
                        case let .chord(_, _, _, stemOrigin, _, _, _, _, _, _):
                            chordXs.append(stemOrigin.x)
                        default:
                            break
                        }
                    }
                }
            }
            return (breaths, chordXs)
        }

        @Test("LayoutEngine emits a .breath element between the two chords")
        func breathElementEmitted() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.breathBetweenChordsScore())
            let (breaths, chordXs) = Self.collectBreathsAndChords(doc)
            try #require(
                breaths.count == 1,
                "expected exactly one .breath element, got \(breaths.count)",
            )
            try #require(chordXs.count == 2)
            let (kind, origin, visible) = breaths[0]
            #expect(kind == .breathMark(.comma))
            #expect(visible)
            // X sits strictly BETWEEN the two chords.
            let cX = chordXs[0]
            let dX = chordXs[1]
            #expect(
                origin.x > cX && origin.x < dX,
                "breath x \(origin.x) must sit strictly between C4 x \(cX) and D4 x \(dX)",
            )
        }

        @Test("Hidden breath is dropped unless showsInvisibleElements")
        func hiddenBreathDropped() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.breathBetweenChordsScore(visible: false)
            let docOff = Self.laidOut(score, showsInvisibleElements: false)
            let docOn = Self.laidOut(score, showsInvisibleElements: true)
            let (breathsOff, _) = Self.collectBreathsAndChords(docOff)
            let (breathsOn, _) = Self.collectBreathsAndChords(docOn)
            #expect(
                breathsOff.isEmpty,
                "hidden breath should NOT appear when showsInvisibleElements is off; got \(breathsOff.count)",
            )
            #expect(
                breathsOn.contains(where: { !$0.2 }),
                "hidden breath should appear when showsInvisibleElements is on",
            )
        }

        @Test("Caesura kind round-trips through the layout element")
        func caesuraKindRoundTrips() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(
                Self.breathBetweenChordsScore(kind: .caesura(.normal)),
            )
            let (breaths, _) = Self.collectBreathsAndChords(doc)
            try #require(breaths.count == 1)
            #expect(breaths[0].0 == .caesura(.normal))
        }
    }
#endif
