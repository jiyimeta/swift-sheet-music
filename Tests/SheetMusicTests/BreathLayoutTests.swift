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

        /// Collect breaths from `measure.elements` (visible bucket) and
        /// `measure.invisibleElements` (hidden bucket, only populated when
        /// `showsInvisibleElements` is on) along with the chord stem-X
        /// positions, for ordering assertions.
        @available(macOS 15.0, iOS 16.0, *)
        private static func collectBreathsAndChords(
            _ doc: LayoutDocument,
        ) -> (
            visibleBreaths: [(Breath.Kind, CGPoint)],
            invisibleBreaths: [(Breath.Kind, CGPoint)],
            chordXs: [CGFloat],
        ) {
            var visibleBreaths: [(Breath.Kind, CGPoint)] = []
            var invisibleBreaths: [(Breath.Kind, CGPoint)] = []
            var chordXs: [CGFloat] = []
            for system in doc.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        switch el {
                        case let .breath(kind, origin):
                            visibleBreaths.append((kind, origin))
                        case let .chord(_, _, _, stemOrigin, _, _, _, _, _, _, _):
                            chordXs.append(stemOrigin.x)
                        default:
                            break
                        }
                    }
                    for el in measure.invisibleElements {
                        if case let .breath(kind, origin) = el {
                            invisibleBreaths.append((kind, origin))
                        }
                    }
                }
            }
            return (visibleBreaths, invisibleBreaths, chordXs)
        }

        @Test("LayoutEngine emits a .breath element between the two chords")
        func breathElementEmitted() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.breathBetweenChordsScore())
            let (visible, invisible, chordXs) = Self.collectBreathsAndChords(doc)
            try #require(
                visible.count == 1,
                "expected exactly one visible .breath element, got \(visible.count)",
            )
            #expect(invisible.isEmpty)
            try #require(chordXs.count == 2)
            let (kind, origin) = visible[0]
            #expect(kind == .breathMark(.comma))
            // X sits strictly BETWEEN the two chords AND is biased
            // toward the following chord (right-aligned: glyph reads
            // as belonging to the next chord, similar to how an
            // accidental sits left of its notehead).
            let cX = chordXs[0]
            let dX = chordXs[1]
            #expect(
                origin.x > cX && origin.x < dX,
                "breath x \(origin.x) must sit strictly between C4 x \(cX) and D4 x \(dX)",
            )
            let midpoint = (cX + dX) / 2
            #expect(
                origin.x > midpoint,
                """
                breath x \(origin.x) should sit past the midpoint \
                \(midpoint) (biased toward following chord at \(dX))
                """,
            )
        }

        @Test("Hidden breath is dropped unless showsInvisibleElements")
        func hiddenBreathDropped() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.breathBetweenChordsScore(visible: false)
            let docOff = Self.laidOut(score, showsInvisibleElements: false)
            let docOn = Self.laidOut(score, showsInvisibleElements: true)
            let off = Self.collectBreathsAndChords(docOff)
            let on = Self.collectBreathsAndChords(docOn)
            // Toggle off: hidden breath appears in NEITHER bucket.
            #expect(
                off.visibleBreaths.isEmpty && off.invisibleBreaths.isEmpty,
                "hidden breath should NOT appear when showsInvisibleElements is off",
            )
            // Toggle on: hidden breath lands in the invisibleElements bucket,
            // matching the convention used by `.fermata`.
            #expect(on.visibleBreaths.isEmpty)
            #expect(
                on.invisibleBreaths.count == 1,
                """
                hidden breath should appear in measure.invisibleElements \
                when showsInvisibleElements is on; \
                got \(on.invisibleBreaths.count)
                """,
            )
        }

        @Test("Caesura kind round-trips through the layout element")
        func caesuraKindRoundTrips() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(
                Self.breathBetweenChordsScore(kind: .caesura(.normal)),
            )
            let (visible, _, _) = Self.collectBreathsAndChords(doc)
            try #require(visible.count == 1)
            #expect(visible[0].0 == .caesura(.normal))
        }

        @Test("BreathGlyph.codepoint resolves to a valid UnicodeScalar for every kind")
        func allKindsResolveToValidScalars() {
            let allKinds: [Breath.Kind] = (
                Breath.BreathMarkStyle.allCases.map { .breathMark($0) }
                    + Breath.CaesuraStyle.allCases.map { .caesura($0) },
            )
            #expect(allKinds.count == 8)
            for kind in allKinds {
                let codepoint = BreathGlyph.codepoint(forKind: kind)
                let scalar = UnicodeScalar(codepoint)
                let hex = String(codepoint, radix: 16, uppercase: true)
                #expect(
                    scalar != nil,
                    "codepoint U+\(hex) for \(kind) is not a valid Unicode scalar",
                )
            }
        }
    }
#endif
