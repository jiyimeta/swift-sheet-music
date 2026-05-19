#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutEngine articulation emission")
    struct LayoutArticulationTests {
        private let _installApple = TestSupport.installApple

        /// Build a one-measure score whose single chord has `articulations`.
        /// `pitch` controls staff position (60 = middle C, treble; 71 = B
        /// just above the middle line).
        private static func score(
            pitch: Int = 60,
            articulations: [ChordArticulation] = [],
        ) -> Score {
            let note = Note(pitch: pitch, tpc: 14)
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([note]),
                articulations: articulations,
            )
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
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

        /// Pull the single articulation + chord from a single-measure
        /// single-staff document. Returns `nil` if not exactly one of each.
        @available(macOS 15.0, iOS 16.0, *)
        private static func soleArtAndChord(
            _ doc: LayoutDocument,
        ) -> (LayoutElement, LayoutElement)? {
            guard let measure = doc.systems.first?.measures.first
            else { return nil }
            var art: LayoutElement?
            var chord: LayoutElement?
            for el in measure.elements {
                if case .articulation = el {
                    if art != nil { return nil }
                    art = el
                }
                if case .chord = el {
                    if chord != nil { return nil }
                    chord = el
                }
            }
            guard let a = art, let c = chord else { return nil }
            return (a, c)
        }

        @Test("Explicit above anchor emits one .articulation with isAbove=true")
        func explicitAboveAnchor() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                articulations: [.init(kind: .staccato, anchor: .above)],
            ))
            let (art, chord) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(kind, origin, isAbove) = art
            else { Issue.record("not articulation"); return }
            guard case let .chord(notes, _, _, _, _, _, _, _, _) = chord
            else { Issue.record("not chord"); return }
            #expect(kind == .staccato)
            #expect(isAbove == true)
            let noteY = try #require(notes.first?.origin.y)
            #expect(origin.y <= noteY - doc.metrics.sp * 0.5 + 0.001)
        }

        @Test("Explicit below anchor emits isAbove=false")
        func explicitBelowAnchor() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                articulations: [.init(kind: .staccato, anchor: .below)],
            ))
            let (art, chord) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(_, origin, isAbove) = art
            else { Issue.record("not articulation"); return }
            guard case let .chord(notes, _, _, _, _, _, _, _, _) = chord
            else { Issue.record("not chord"); return }
            #expect(isAbove == false)
            let noteY = try #require(notes.first?.origin.y)
            #expect(origin.y >= noteY + doc.metrics.sp * 0.5 - 0.001)
        }

        @Test("Auto anchor on stem-up chord lands below (opposite-side rule)")
        func autoAnchorStemUp() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                pitch: 60,
                articulations: [.init(kind: .staccato, anchor: nil)],
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(_, _, isAbove) = art
            else { Issue.record("not articulation"); return }
            #expect(isAbove == false)
        }

        @Test("Auto anchor on stem-down chord lands above")
        func autoAnchorStemDown() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                pitch: 79,
                articulations: [.init(kind: .staccato, anchor: nil)],
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(_, _, isAbove) = art
            else { Issue.record("not articulation"); return }
            #expect(isAbove == true)
        }

        @Test("Above placement pushes past the top staff line")
        func outsideStaffPushAbove() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                pitch: 71,
                articulations: [.init(kind: .staccato, anchor: .above)],
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(_, origin, _) = art
            else { Issue.record("not articulation"); return }
            guard let system = doc.systems.first,
                  let staffOriginY = system.staffOrigins.first?.y
            else { Issue.record("no staff origin"); return }
            let sp = doc.metrics.sp
            let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
            let staffTopY = staffMidY - sp * 2
            #expect(origin.y <= staffTopY - sp * 0.5 + 0.001)
        }

        @Test("Below placement pushes past the bottom staff line")
        func outsideStaffPushBelow() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                pitch: 71,
                articulations: [.init(kind: .staccato, anchor: .below)],
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(_, origin, _) = art
            else { Issue.record("not articulation"); return }
            guard let system = doc.systems.first,
                  let staffOriginY = system.staffOrigins.first?.y
            else { Issue.record("no staff origin"); return }
            let sp = doc.metrics.sp
            let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
            let staffBottomY = staffMidY + sp * 2
            #expect(origin.y >= staffBottomY + sp * 0.5 - 0.001)
        }

        @Test("Two above-anchored articulations stack 1 sp apart")
        func stacking() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                articulations: [
                    .init(kind: .staccato, anchor: .above),
                    .init(kind: .tenuto, anchor: .above),
                ],
            ))
            guard let measure = doc.systems.first?.measures.first
            else { Issue.record("no measure"); return }
            let arts = measure.elements.compactMap { el -> CGFloat? in
                if case let .articulation(_, p, _) = el { return p.y }
                return nil
            }
            #expect(arts.count == 2)
            try #require(arts.count == 2)
            let delta = arts[0] - arts[1]
            #expect(abs(delta - doc.metrics.sp) < 0.001)
        }

        @Test("Unknown articulation kind emits no .articulation element")
        func unknownIsFiltered() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.laidOut(Self.score(
                articulations: [
                    .init(
                        kind: .unknown(subtype: "articAccentAbove"),
                        anchor: .above,
                    ),
                ],
            ))
            guard let measure = doc.systems.first?.measures.first
            else { Issue.record("no measure"); return }
            let count = measure.elements.reduce(into: 0) { acc, el in
                if case .articulation = el { acc += 1 }
            }
            #expect(count == 0)
        }

        @Test("Kind mapping covers staccatissimo and tenuto")
        func kindMapping() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            for (input, expected) in [
                (
                    ChordArticulation.Kind.staccatissimo,
                    LayoutElement.ArticulationKind.staccatissimo,
                ),
                (.tenuto, .tenuto),
            ] {
                let doc = Self.laidOut(Self.score(
                    articulations: [.init(kind: input, anchor: .above)],
                ))
                let (art, _) = try #require(Self.soleArtAndChord(doc))
                guard case let .articulation(kind, _, _) = art
                else { Issue.record("not articulation"); return }
                #expect(kind == expected)
            }
        }
    }
#endif
