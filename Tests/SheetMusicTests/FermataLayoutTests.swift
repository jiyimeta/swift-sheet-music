#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutEngine fermata anchor placement")
    struct FermataLayoutTests {
        private let _installApple = TestSupport.installApple

        /// Build a one-measure score whose voice contains
        /// `[chord(C4), fermata, chord(D4)]` — the canonical MusicXML
        /// ordering where the fermata appears BEFORE its target chord.
        private static func fermataBeforeTargetScore() -> Score {
            let cChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            )
            let dChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
            )
            let fermata = Fermata(subtype: "fermataAbove")
            let voice = Voice(elements: [
                .chord(cChord),
                .fermata(fermata),
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

        /// Build the inverse layout: `[chord(C4), chord(D4), fermata]` —
        /// the MSCX shape where Fermata is a sibling AFTER its target.
        /// The backward fallback should anchor the fermata to D4.
        private static func fermataAfterTargetScore() -> Score {
            let cChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            )
            let dChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
            )
            let fermata = Fermata(subtype: "fermataAbove")
            let voice = Voice(elements: [
                .chord(cChord),
                .chord(dChord),
                .fermata(fermata),
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
        private static func laidOut(_ s: Score) -> LayoutDocument {
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
            return LayoutEngine.layout(
                score: s, options: opts, availableWidth: natW,
            )
        }

        /// Pull (fermataX, chordXs) from the first measure.
        @available(macOS 15.0, iOS 16.0, *)
        private static func fermataAndChordXs(
            _ doc: LayoutDocument,
        ) -> (CGFloat, [CGFloat])? {
            guard let measure = doc.systems.first?.measures.first
            else { return nil }
            var fermataX: CGFloat?
            var chordXs: [CGFloat] = []
            for el in measure.elements {
                switch el {
                case let .fermata(_, origin):
                    fermataX = origin.x
                case let .chord(_, _, _, stemOrigin, _, _, _, _):
                    chordXs.append(stemOrigin.x)
                default:
                    break
                }
            }
            guard let fx = fermataX else { return nil }
            return (fx, chordXs)
        }

        @Test("Fermata before chord anchors to the FOLLOWING chord (MusicXML order)")
        func anchorForward() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataBeforeTargetScore())
            let (fermataX, chordXs) = try #require(
                Self.fermataAndChordXs(doc),
            )
            try #require(chordXs.count == 2)
            // Expectation: fermata anchors to D4 (second chord), NOT C4 (first).
            #expect(
                abs(fermataX - chordXs[1]) < 0.001,
                "fermata x \(fermataX) should match D4 x \(chordXs[1]); C4 x is \(chordXs[0])",
            )
            #expect(
                abs(fermataX - chordXs[0]) > 0.5,
                "fermata x \(fermataX) should NOT match C4 x \(chordXs[0])",
            )
        }

        @Test("Fermata after chord falls back to PRECEDING chord (MSCX order)")
        func anchorBackwardFallback() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataAfterTargetScore())
            let (fermataX, chordXs) = try #require(
                Self.fermataAndChordXs(doc),
            )
            try #require(chordXs.count == 2)
            // No following chord exists, so the backward fallback must
            // anchor to the most recent chord (D4 — the second one).
            #expect(
                abs(fermataX - chordXs[1]) < 0.001,
                "fermata x \(fermataX) should match D4 x \(chordXs[1])",
            )
        }

        /// Fermata-above target chord has a notehead well above the top
        /// staff line, so the chord's north skyline rises above the
        /// fermata's default Y (`staffMidY - 3 sp`). The fermata must
        /// be pushed further up so it clears the notehead by ≥ 0.5 sp.
        private static func fermataAboveHighChordScore() -> Score {
            // G6 (pitch 91) in treble clef → step ≈ +12, notehead ≈ 6 sp
            // above the top staff line.
            let highChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 91, tpc: 15)]),
            )
            let fermata = Fermata(subtype: "fermataAbove")
            let voice = Voice(elements: [
                .fermata(fermata),
                .chord(highChord),
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

        /// Fermata-below a low chord whose stem-up reaches well below the
        /// staff. Used to verify the south-skyline mirroring path.
        private static func fermataBelowLowChordScore() -> Score {
            // C2 (pitch 36) in treble clef → step ≈ -20; stem-up because
            // the chord sits far below the middle line. Notehead alone is
            // already ~10 sp below `staffMidY`.
            let lowChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 36, tpc: 14)]),
            )
            let fermata = Fermata(subtype: "fermataBelow")
            let voice = Voice(elements: [
                .fermata(fermata),
                .chord(lowChord),
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

        /// Pull the first fermata's origin and the first chord's notehead
        /// extents (top, bottom) from a single-measure layout document.
        @available(macOS 15.0, iOS 16.0, *)
        private static func fermataAndChordExtents(
            _ doc: LayoutDocument,
        ) -> (fermataOrigin: CGPoint, chordTopY: CGFloat, chordBottomY: CGFloat)? {
            guard let measure = doc.systems.first?.measures.first
            else { return nil }
            var fermataOrigin: CGPoint?
            var noteYs: [CGFloat] = []
            for el in measure.elements {
                switch el {
                case let .fermata(_, origin):
                    fermataOrigin = origin
                case let .chord(notes, _, _, _, _, _, _, _):
                    noteYs.append(contentsOf: notes.map(\.origin.y))
                default:
                    break
                }
            }
            guard let f = fermataOrigin,
                  let top = noteYs.min(),
                  let bot = noteYs.max()
            else { return nil }
            return (f, top, bot)
        }

        @Test("fermataAbove clears chord north skyline (high notehead)")
        func aboveClearsHighChord() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataAboveHighChordScore())
            let (fermata, chordTopY, _) = try #require(
                Self.fermataAndChordExtents(doc),
            )
            let sp: CGFloat = 28.0 / 4 // staffSize=28
            // Glyph anchor is .center but Bravura's typographic bbox is
            // asymmetric — use the runtime-measured bottom offset so the
            // assertion matches the actual screen geometry.
            let glyphBottom = fermata.y
                + FermataGlyphMetrics.above.bottomOffset * sp
            #expect(
                glyphBottom <= chordTopY - sp * 0.5,
                "fermata glyph bottom \(glyphBottom) must clear notehead top \(chordTopY) by ≥ 0.5 sp",
            )
        }

        @Test("fermataBelow clears chord south skyline (low notehead)")
        func belowClearsLowChord() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataBelowLowChordScore())
            let (fermata, _, chordBottomY) = try #require(
                Self.fermataAndChordExtents(doc),
            )
            let sp: CGFloat = 28.0 / 4 // staffSize=28
            // Use runtime-measured top offset for the same reason as
            // above: typographic bbox is asymmetric.
            let glyphTop = fermata.y
                + FermataGlyphMetrics.below.topOffset * sp
            #expect(
                glyphTop >= chordBottomY + sp * 0.5,
                "fermata glyph top \(glyphTop) must clear notehead bottom \(chordBottomY) by ≥ 0.5 sp",
            )
        }

        /// Build a one-measure score whose voice contains
        /// `[fermata, chord(B4)]`. B4 in treble clef sits on the middle
        /// staff line and has a stem-up reaching ~3.5 sp above it (i.e.
        /// ~1.5 sp above the top staff line). The fermata must clear the
        /// stem TOP, not just the notehead.
        private static func fermataAboveStemUpChordScore() -> Score {
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 71, tpc: 18)]),
            )
            let fermata = Fermata(subtype: "fermataAbove")
            let voice = Voice(elements: [
                .fermata(fermata),
                .chord(chord),
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

        /// Two beamed 8ths: A3 (step -5) and B4 (step 0). Both at-or-
        /// below the middle staff line so the group's stem direction is
        /// UP. The interval (5 steps) exceeds the per-beam slope cap, so
        /// the beam slope is shorter than the anchor difference — the A3
        /// stem must therefore extend much higher than its STANDALONE
        /// `defaultStemLength` would put it (the beam Y at A3's stem-X is
        /// pulled up by the cap). A fermata anchored to A3 must clear
        /// the post-beam stem top, not just A3's standalone extension.
        private static func fermataOnBeamedHighChordScore() -> Score {
            let a3 = Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 57, tpc: 17)]),
            )
            let b4 = Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 71, tpc: 18)]),
            )
            let fermata = Fermata(subtype: "fermataAbove")
            let voice = Voice(elements: [
                .fermata(fermata),
                .chord(a3),
                .chord(b4),
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

        @Test("fermataAbove clears beam-extended stem on first member")
        func aboveClearsBeamedStem() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataOnBeamedHighChordScore())
            guard let measure = doc.systems.first?.measures.first
            else { Issue.record("no measure"); return }
            var fermataY: CGFloat?
            var firstChordStemTopY: CGFloat?
            var firstChordSeen = false
            for el in measure.elements {
                switch el {
                case let .fermata(_, origin):
                    fermataY = origin.y
                case let .chord(_, _, stem, stemOrigin, _, _, _, _):
                    // First chord emitted is B4. For stem-up, post-beam
                    // pass writes the beam Y into stemOrigin.y.
                    if !firstChordSeen {
                        firstChordSeen = true
                        if stem == .up {
                            firstChordStemTopY = stemOrigin.y
                        }
                    }
                default: break
                }
            }
            let sp: CGFloat = 28.0 / 4
            let f = try #require(fermataY)
            let stemTop = try #require(firstChordStemTopY)
            let glyphBottom = f + FermataGlyphMetrics.above.bottomOffset * sp
            #expect(
                glyphBottom <= stemTop - sp * 0.5,
                "fermata glyph bottom \(glyphBottom) must clear post-beam stem top \(stemTop) by >= 0.5 sp",
            )
        }

        @Test("fermataAbove clears stem-up endpoint")
        func aboveClearsStemUp() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.fermataAboveStemUpChordScore())
            guard let measure = doc.systems.first?.measures.first
            else { Issue.record("no measure"); return }
            var fermataY: CGFloat?
            var stemTopY: CGFloat?
            for el in measure.elements {
                switch el {
                case let .fermata(_, origin):
                    fermataY = origin.y
                case let .chord(notes, _, stem, stemOrigin, _, _, _, _):
                    // For stem-up, `LayoutEngine+Extents.chordTopExtent`
                    // treats `min(stemOrigin.y, topNote)` as the chord
                    // top — i.e. `stemOrigin.y` IS the stem-top endpoint
                    // for stem-up. Use it directly.
                    if stem == .up {
                        stemTopY = stemOrigin.y
                    } else if let highest = notes.map(\.origin.y).min() {
                        stemTopY = highest
                    }
                default:
                    break
                }
            }
            let sp: CGFloat = 28.0 / 4
            let f = try #require(fermataY)
            let stemTop = try #require(stemTopY)
            let glyphBottom = f + FermataGlyphMetrics.above.bottomOffset * sp
            #expect(
                glyphBottom <= stemTop - sp * 0.5,
                "fermata glyph bottom \(glyphBottom) must clear stem top \(stemTop) by ≥ 0.5 sp",
            )
        }
    }
#endif
