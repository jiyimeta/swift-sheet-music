#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// The resolve / attach pass that turns `Chord.spanners` slurs into
    /// `LayoutElement.tieArc` — the same element (and the same attach body)
    /// ties use, since a slur pair is structurally a `TiePair`.
    @Suite("Chord-anchored slur layout")
    struct SlurLayoutTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        /// Every vendored slur reaches the page. Counted as a DELTA against
        /// the same score with `Chord.spanners` emptied, because ties emit
        /// `.tieArc` too and `slur_ms4_glissando_legato` carries ties of its
        /// own; `>=` rather than `==` because a slur crossing a system break
        /// emits two segments.
        ///
        /// `MSCXParser.parse` (not `parseWithDiagnostics`) on purpose:
        /// `slur_ms3_exchangevoices` decodes with `mscx.slur.locationDropped`
        /// for its cross-voice slur, which is a known, gated loss
        /// (`SlurLocationDiagnosticsTests`), not this pass's business.
        ///
        /// All THREE MS3 slurs are expected, the cross-voice one included:
        /// the model cannot see its `<voices>` hop, so the end resolves to
        /// the chord at the target position *in the same voice* and the arc
        /// is drawn there — exactly what the encoder does with the same
        /// missing field.
        @Test("every fixture slur adds an arc", arguments: [
            ("slur_ms4_glissando_legato", 2),
            ("slur_ms3_exchangevoices", 3),
        ])
        func fixtureSlursEmitArcs(_ fixture: String, _ slurCount: Int) throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = try MSCXParser.parse(
                MSCXFixtureLoader.mscxData(fixture),
            )
            try #require(Self.slurCount(in: score) == slurCount)
            let withSlurs = Self.arcCount(in: Self.layout(score))
            let without = Self.arcCount(
                in: Self.layout(Self.strippingChordSpanners(score)),
            )
            #expect(withSlurs - without >= slurCount)
        }

        // MARK: - Same-measure pair

        /// Two quarter chords, `<fractions>1/4</fractions>` apart. The raw
        /// pair endpoints are the two noteheads' absolute origins — the head
        /// clearance lives inside `TieArcGeometry`, not here — and both
        /// chords are stem-DOWN (above the middle line), so MuseScore's
        /// stem-opposite branch puts the slur above.
        @Test("a same-measure slur pairs the two noteheads, arcing above")
        func sameMeasureSlurPairsNoteheads() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.twoChordScore(slur: Self.slur())
            let doc = Self.layout(score)
            let pairs = LayoutEngine.resolveSlurs(for: doc, score: score)
            #expect(pairs.count == 1)
            #expect(Self.arcCount(in: doc) == 1)
            let origins = Self.noteOrigins(in: doc)
            guard let pair = pairs.first, origins.count >= 2 else { return }
            #expect(pair.above)
            #expect(pair.fromOrigin == origins[0])
            #expect(pair.toOrigin == origins[1])
        }

        // MARK: - Direction

        /// `<placement>` is an author override and wins outright — tested in
        /// BOTH directions so neither answer can be the accidental default:
        /// `below` on a stem-down pair (whose automatic side is above) and
        /// `above` on a stem-up pair (whose automatic side is below).
        @Test("an authored placement wins over the computed side", arguments: [
            (Spanner.Placement.below, 79, 77, false),
            (Spanner.Placement.above, 60, 62, true),
        ])
        func placementOverridesComputedSide(
            _ placement: Spanner.Placement,
            _ firstPitch: Int,
            _ secondPitch: Int,
            _ expectedAbove: Bool,
        ) {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let plain = Self.twoChordScore(
                slur: Self.slur(), firstPitch: firstPitch,
                secondPitch: secondPitch,
            )
            let plainPairs = LayoutEngine.resolveSlurs(
                for: Self.layout(plain), score: plain,
            )
            // Gate: without the override this pair takes the OTHER side, so
            // the assertion below is evidence the override did the work.
            #expect(plainPairs.first?.above == !expectedAbove)

            let score = Self.twoChordScore(
                slur: Self.slur(placement: placement), firstPitch: firstPitch,
                secondPitch: secondPitch,
            )
            let pairs = LayoutEngine.resolveSlurs(
                for: Self.layout(score), score: score,
            )
            #expect(pairs.first?.above == expectedAbove)
        }

        /// MuseScore's multi-voice branch (`slurtielayout.cpp:2619-2625`):
        /// once any measure the slur spans carries more than one voice, the
        /// side is decided by voice index alone — voice 0 above, any other
        /// below — and the stem-opposite result computed at `:2606` is
        /// overwritten.
        ///
        /// BOTH cases discriminate. Two voices force stems by parity
        /// (`LayoutEngine+Placement.swift:274-276`, voice 0 up / voice 1
        /// down) regardless of pitch, so the stem-opposite answer would be
        /// `below` for voice 0 and `above` for voice 1 — the exact inverse
        /// of what the parity branch returns in each case.
        @Test("in a multi-voice measure the side follows the voice index")
        func multiVoiceParityDecidesSide() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            for slurVoice in 0 ... 1 {
                let score = Self.twoVoiceScore(slurVoice: slurVoice)
                let pairs = LayoutEngine.resolveSlurs(
                    for: Self.layout(score), score: score,
                )
                #expect(pairs.count == 1)
                #expect(pairs.first?.above == (slurVoice == 0))
            }
        }

        /// A slur starting on a REST arcs BELOW, and does so whether or not
        /// the measure carries a second voice.
        ///
        /// A Rest is a `ChordRest` in MuseScore, so `computeUp`'s
        /// `chordRest1 == 0` guard (`:2583`) does not fire; control reaches
        /// `slur->setUp(!(chordRest1->up()))` (`:2606`) and `ChordRest::up`
        /// defaults to `true` (`dom/chordrest.h:197`) for want of a stem —
        /// so `setUp(false)`. The multi-voice case must agree, because
        /// `:2612-2613` guards `multipleVoices` with `&& chord1`, which is
        /// null for a rest start: the parity branch that would otherwise
        /// return `above` for voice 0 never runs.
        @Test("a slur starting on a rest arcs below", arguments: [false, true])
        func restStartArcsBelow(_ multiVoice: Bool) {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.restStartScore(multiVoice: multiVoice)
            let doc = Self.layout(score)
            let pairs = LayoutEngine.resolveSlurs(for: doc, score: score)
            #expect(pairs.count == 1)
            #expect(pairs.first?.above == false)
            #expect(Self.arcCount(in: doc) == 1)
        }

        /// The rest end of such a slur anchors at the rest glyph's own
        /// origin, not at a notehead.
        @Test("a rest endpoint anchors on the rest glyph")
        func restEndpointIsTheRestOrigin() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.restStartScore(multiVoice: false)
            let doc = Self.layout(score)
            let pairs = LayoutEngine.resolveSlurs(for: doc, score: score)
            guard let pair = pairs.first,
                  let rest = Self.firstRestOrigin(in: doc)
            else {
                Issue.record("expected one pair and one laid-out rest")
                return
            }
            #expect(pair.fromOrigin == rest)
        }

        // MARK: - Cross-system

        /// A slur whose end sits in the next system splits into the same two
        /// segments a tie does: a BEGIN half running out to the source
        /// system's right edge, and an END half starting past the synthesised
        /// clef / key signature rather than at x = 0.
        @Test("a slur across a system break attaches a half-arc to both")
        func crossSystemSlurSplits() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.twoMeasureScore(
                slur: Self.slur(measures: 1, fractions: nil),
            )
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(wrapToViewWidth: true),
                availableWidth: 200,
            )
            // Sanity: the narrow width really did break the system, so the
            // two-segment assertions below mean what they say.
            #expect(doc.systems.count == 2)
            guard doc.systems.count == 2 else { return }
            let pairs = LayoutEngine.resolveSlurs(for: doc, score: score)
            #expect(pairs.count == 1)
            let first = Self.arcs(in: doc.systems[0])
            let second = Self.arcs(in: doc.systems[1])
            #expect(first.count == 1)
            #expect(second.count == 1)
            if let arc = first.first {
                #expect(arc.to.x >= doc.systems[0].size.width - 4)
            }
            if let arc = second.first {
                #expect(arc.from.x > 0)
            }
        }

        // MARK: - Unresolvable ends

        /// An offset that runs off the end of the score has no end chord.
        /// Dropped in silence, the way `resolveTies` drops an unmatched tie.
        @Test("an end past the last measure emits nothing")
        func endPastTheScoreDropsSilently() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.twoChordScore(
                slur: Self.slur(measures: 5, fractions: nil),
            )
            let doc = Self.layout(score)
            #expect(LayoutEngine.resolveSlurs(for: doc, score: score).isEmpty)
            #expect(Self.arcCount(in: doc) == 0)
        }

        /// A fractional offset landing between chords resolves to no
        /// chord/rest at all — also a silent drop, not a nearest-neighbour
        /// guess.
        @Test("an offset landing off the grid emits nothing")
        func offGridOffsetDropsSilently() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.twoChordScore(
                slur: Self.slur(fractions: Fraction(numerator: 1, denominator: 8)),
            )
            let doc = Self.layout(score)
            #expect(LayoutEngine.resolveSlurs(for: doc, score: score).isEmpty)
            #expect(Self.arcCount(in: doc) == 0)
        }

        // MARK: - Helpers

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
        }

        private static func slur(
            measures: Int = 0,
            fractions: Fraction? = Fraction(numerator: 1, denominator: 4),
            placement: Spanner.Placement? = nil,
        ) -> Spanner {
            Spanner(
                kind: .slur, rawType: "Slur",
                nextMeasuresOffset: measures,
                nextFractionsOffset: fractions,
                placement: placement,
            )
        }

        /// One measure, one voice, two quarter chords; the slur rides the
        /// first. Default pitches sit above the middle line, so both chords
        /// are stem-down.
        private static func twoChordScore(
            slur: Spanner, firstPitch: Int = 79, secondPitch: Int = 77,
        ) -> Score {
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: firstPitch, tpc: 15)],
                    spanners: [slur],
                )),
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: secondPitch, tpc: 13)],
                )),
            ])])
            return score(measures: [measure])
        }

        /// Two whole-note measures; the slur runs from the first to the
        /// second.
        private static func twoMeasureScore(slur: Spanner) -> Score {
            let first = Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .whole, notes: [Note(pitch: 79, tpc: 15)],
                    spanners: [slur],
                )),
            ])])
            let second = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [Note(pitch: 77, tpc: 13)])),
            ])])
            return score(measures: [first, second])
        }

        /// One measure carrying two voices of two quarters each. The slur
        /// sits on the first chord of `slurVoice`.
        private static func twoVoiceScore(slurVoice: Int) -> Score {
            func voice(_ index: Int, pitch: Int, tpc: Int) -> Voice {
                Voice(elements: [
                    .chord(Chord(
                        duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)],
                        spanners: index == slurVoice ? [slur()] : [],
                    )),
                    .chord(Chord(
                        duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)],
                    )),
                ])
            }
            let measure = Measure(voices: [
                voice(0, pitch: 79, tpc: 15),
                voice(1, pitch: 77, tpc: 13),
            ])
            return score(measures: [measure])
        }

        /// One measure whose voice 0 opens with a slur-bearing quarter REST
        /// (a note-less `Chord`) followed by the chord the slur ends on.
        /// `multiVoice` adds a second, fully populated voice so the parity
        /// branch would fire if it were not skipped for a rest start.
        private static func restStartScore(multiVoice: Bool) -> Score {
            let lead = Voice(elements: [
                .chord(Chord(
                    duration: .quarter, notes: [], spanners: [slur()],
                )),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 79, tpc: 15)],
                )),
            ])
            let second = Voice(elements: [
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
                )),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 62, tpc: 16)],
                )),
            ])
            return score(measures: [
                Measure(voices: multiVoice ? [lead, second] : [lead]),
            ])
        }

        /// Absolute origin of the first laid-out rest glyph.
        private static func firstRestOrigin(
            in document: LayoutDocument,
        ) -> CGPoint? {
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        guard case let .rest(_, origin, _, _, _) = element
                        else { continue }
                        return CGPoint(
                            x: system.origin.x + measure.origin.x + origin.x,
                            y: system.origin.y + measure.origin.y + origin.y,
                        )
                    }
                }
            }
            return nil
        }

        private static func score(measures: [Measure]) -> Score {
            Score(division: 480, parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: measures)],
            )])
        }

        private static func arcs(
            in system: LayoutSystem,
        ) -> [(from: CGPoint, to: CGPoint, above: Bool)] {
            system.spanners.compactMap { element in
                guard case let .tieArc(from, to, above) = element else {
                    return nil
                }
                return (from: from, to: to, above: above)
            }
        }

        private static func arcCount(in document: LayoutDocument) -> Int {
            document.systems.reduce(0) { $0 + arcs(in: $1).count }
        }

        /// Absolute origin of every laid-out notehead, in system / measure /
        /// element order — the frame `resolveSlurs` reports its pairs in.
        private static func noteOrigins(in document: LayoutDocument) -> [CGPoint] {
            var out: [CGPoint] = []
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                            = element
                        else { continue }
                        out.append(contentsOf: notes.map { note in
                            CGPoint(
                                x: system.origin.x + measure.origin.x
                                    + note.origin.x,
                                y: system.origin.y + measure.origin.y
                                    + note.origin.y,
                            )
                        })
                    }
                }
            }
            return out
        }

        private static func slurCount(in score: Score) -> Int {
            score.allStaves.reduce(0) { total, entry in
                total + entry.staff.measures.reduce(0) { measureTotal, measure in
                    measureTotal + measure.voices.reduce(0) { voiceTotal, voice in
                        voiceTotal + voice.elements.reduce(0) { elementTotal, element in
                            guard case let .chord(chord) = element else {
                                return elementTotal
                            }
                            return elementTotal
                                + chord.spanners.filter { $0.kind == .slur }.count
                        }
                    }
                }
            }
        }

        /// The same score with every chord-anchored spanner removed — the
        /// baseline the fixture delta is measured against.
        private static func strippingChordSpanners(_ score: Score) -> Score {
            var stripped = score
            stripped.parts = score.parts.map { part in
                var part = part
                part.staves = part.staves.map { staff in
                    var staff = staff
                    staff.measures = staff.measures.map(strippingMeasure)
                    return staff
                }
                return part
            }
            return stripped
        }

        private static func strippingMeasure(_ measure: Measure) -> Measure {
            var measure = measure
            measure.voices = measure.voices.map { voice in
                var voice = voice
                voice.elements = voice.elements.map { element in
                    guard case let .chord(chord) = element else { return element }
                    var bare = chord
                    bare.spanners = []
                    return .chord(bare)
                }
                return voice
            }
            return measure
        }
    }
#endif
