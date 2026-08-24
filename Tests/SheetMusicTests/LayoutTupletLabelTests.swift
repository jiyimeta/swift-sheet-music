#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A tuplet is a rhythmic statement, not a pitch one — so it has to be readable when every member is a rest. The
    /// emitter used to require at least one chord to place the label against, which silently dropped the number and
    /// bracket for a triplet of rests: the score then showed three eighth rests where three-in-the-time-of-two were
    /// meant, with nothing to say so.
    @Suite("LayoutEngine tuplet labels")
    struct LayoutTupletLabelTests {
        private let _installApple = TestSupport.installApple

        /// One 4/4 measure whose first quarter is a triplet of `members`, followed by three quarter rests.
        private func score(members: [VoiceElement]) -> Score {
            var elements: [VoiceElement] = [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            ]
            let tupletStart = elements.count
            elements.append(contentsOf: members)
            elements.append(contentsOf: (0 ..< 3).map { _ in VoiceElement.rest(duration: .quarter) })
            var voice = Voice(elements: elements)
            voice.tuplets = [Tuplet(
                normalNotes: 2,
                actualNotes: 3,
                startIndex: tupletStart,
                endIndex: tupletStart + members.count - 1,
            )]
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(
                        staffType: "stdNormal",
                        group: "pitched",
                        defaultClefType: "G",
                        measures: [Measure(voices: [voice])],
                    )],
                )],
            )
        }

        /// A twelfth — one third of a quarter — as `CreateTuplet` spells it.
        private static let twelfth = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

        private func tupletLabels(in score: Score) -> [LayoutElement] {
            let doc = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
            return doc.systems.flatMap { system in
                system.measures.flatMap { measure in
                    measure.elements.filter {
                        if case .tupletLabel = $0 { return true }
                        return false
                    }
                }
            }
        }

        @Test("A triplet of rests still prints its number and bracket")
        func restOnlyTupletIsLabelled() throws {
            guard #available(macOS 15.0, *) else { return }
            let labels = tupletLabels(in: score(members: (0 ..< 3).map { _ in
                VoiceElement.rest(duration: Self.twelfth)
            }))
            let label = try #require(labels.first)
            guard case let .tupletLabel(fromOrigin, toOrigin, text, hasBracket, _, _) = label else {
                Issue.record("not a tuplet label")
                return
            }
            #expect(text == "3")
            // Nothing is beamed, so the bracket is what carries the span.
            #expect(hasBracket)
            // The span reaches from the first rest to the last — a zero-width bracket would collapse onto one rest.
            #expect(toOrigin.x > fromOrigin.x)
        }

        @Test("A triplet whose first member is a note is labelled as before")
        func mixedTupletIsStillLabelled() throws {
            guard #available(macOS 15.0, *) else { return }
            let labels = tupletLabels(in: score(members: [
                .chord(Chord(duration: Self.twelfth, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: Self.twelfth),
                .rest(duration: Self.twelfth),
            ]))
            let label = try #require(labels.first)
            guard case let .tupletLabel(_, _, text, hasBracket, _, _) = label else {
                Issue.record("not a tuplet label")
                return
            }
            #expect(text == "3")
            #expect(hasBracket)
        }
    }
#endif
