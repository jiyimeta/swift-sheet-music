#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// End-of-system courtesy signatures: when the measure that OPENS the
    /// next system begins with an explicit key / time signature change,
    /// the current system's last measure announces it at its trailing
    /// edge. `showCourtesy == false` on the model element suppresses the
    /// announcement; a change that lands mid-system stays inline.
    @Suite("Courtesy signatures")
    struct CourtesySignatureLayoutTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        enum TestFailure: Error { case notFound(String) }

        // MARK: - Fixtures

        private static func chord() -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            ))
        }

        /// One staff's four bars:
        ///
        /// * m0 — clef + `firstKey` + 4/4, one chord.
        /// * m1 — one chord and NOTHING else, so any signature element
        ///   laid out inside it can only be a courtesy.
        /// * m2 — the change: `secondKey` and, when `timeChange` is set,
        ///   a new time signature too.
        /// * m3 — one chord.
        ///
        /// `breakAfterM1` plants an explicit line break so the change
        /// reliably opens system 2 whatever the available width is.
        private static func staff(
            firstKey: Int,
            secondKey: Int,
            timeChange: (Int, Int)?,
            showCourtesy: Bool,
            breakAfterM1: Bool,
            clefType: String,
        ) -> Staff {
            var key = KeySignature(concertKey: secondKey)
            key.showCourtesy = showCourtesy
            var change: [VoiceElement] = [.keySignature(key)]
            if let timeChange {
                var time = TimeSignature(
                    numerator: timeChange.0, denominator: timeChange.1,
                )
                time.showCourtesy = showCourtesy
                change.append(.timeSignature(time))
            }
            change.append(chord())
            return Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: clefType)),
                    .keySignature(KeySignature(concertKey: firstKey)),
                    .timeSignature(
                        TimeSignature(numerator: 4, denominator: 4),
                    ),
                    chord(),
                ])]),
                Measure(
                    voices: [Voice(elements: [chord()])],
                    lineBreak: breakAfterM1,
                ),
                Measure(voices: [Voice(elements: change)]),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
        }

        private static func score(
            firstKey: Int = 1,
            secondKey: Int = -2,
            timeChange: (Int, Int)? = (3, 4),
            showCourtesy: Bool = true,
            breakAfterM1: Bool = true,
            clefTypes: [String] = ["G"],
        ) -> Score {
            Score(
                division: 480,
                parts: clefTypes.enumerated().map { idx, clefType in
                    Part(
                        id: "P\(idx)",
                        instrument: Instrument(id: "voice\(idx)"),
                        staves: [staff(
                            firstKey: firstKey,
                            secondKey: secondKey,
                            timeChange: timeChange,
                            showCourtesy: showCourtesy,
                            breakAfterM1: breakAfterM1,
                            clefType: clefType,
                        )],
                    )
                },
            )
        }

        private func layout(
            _ score: Score, width: CGFloat = 900,
        ) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: width,
            )
        }

        // MARK: - Readers

        private func measure(
            _ doc: LayoutDocument, _ index: Int,
        ) throws -> LayoutMeasure {
            for system in doc.systems {
                for m in system.measures where m.measureIndex == index {
                    return m
                }
            }
            throw TestFailure.notFound("measure \(index)")
        }

        private func keySignatures(
            _ m: LayoutMeasure,
        ) -> [(sharps: Int, flats: Int, naturals: [Int], origin: CGPoint)] {
            m.elements.compactMap { element in
                guard case let .keySignature(s, f, _, naturals, origin) = element
                else { return nil }
                return (s, f, naturals, origin)
            }
        }

        private func timeSignatures(
            _ m: LayoutMeasure,
        ) -> [(numerator: Int, denominator: Int, origin: CGPoint)] {
            m.elements.compactMap { element in
                guard case let .timeSignature(n, d, origin) = element
                else { return nil }
                return (n, d, origin)
            }
        }

        private func lastNoteheadX(_ m: LayoutMeasure) -> CGFloat {
            var maxX = -CGFloat.infinity
            for element in m.elements {
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                    = element else { continue }
                for note in notes {
                    maxX = max(maxX, note.origin.x)
                }
            }
            return maxX
        }

        /// The system that contains `measureIndex`.
        private func system(
            _ doc: LayoutDocument, containing measureIndex: Int,
        ) throws -> LayoutSystem {
            for system in doc.systems
                where system.measures.contains(
                    where: { $0.measureIndex == measureIndex },
                )
            {
                return system
            }
            throw TestFailure.notFound("system containing \(measureIndex)")
        }

        // MARK: - Tests

        @Test("a break before a change announces key and time")
        func breakBeforeChangeEmitsCourtesyKeyAndTime() throws {
            let doc = layout(Self.score())
            // The break has to have happened, or there is nothing to
            // announce.
            #expect(doc.systems.count >= 2)
            #expect(try system(doc, containing: 1).measures.last?
                .measureIndex == 1)
            let m1 = try measure(doc, 1)
            let keys = keySignatures(m1)
            let times = timeSignatures(m1)
            #expect(keys.count == 1)
            #expect(times.count == 1)
            let key = try #require(keys.first)
            let time = try #require(times.first)
            #expect(key.flats == 2)
            #expect(key.sharps == 0)
            #expect(time.numerator == 3)
            #expect(time.denominator == 4)
            // Trailing: right of the measure's own content, and the time
            // signature right of the key signature.
            #expect(key.origin.x > lastNoteheadX(m1))
            #expect(time.origin.x > key.origin.x)
            // Inside the system it belongs to.
            let sys = try system(doc, containing: 1)
            #expect(m1.origin.x + time.origin.x < sys.size.width)
        }

        @Test("showCourtesy = false suppresses the announcement")
        func courtesyFlagOffEmitsNothing() throws {
            let doc = layout(Self.score(showCourtesy: false))
            let m1 = try measure(doc, 1)
            #expect(keySignatures(m1).isEmpty)
            #expect(timeSignatures(m1).isEmpty)
            // The change itself still renders inline in its own measure.
            #expect(try keySignatures(measure(doc, 2)).count == 1)
        }

        @Test("a mid-system change stays inline and announces nothing")
        func midSystemChangeIsNotAnnounced() throws {
            let doc = layout(
                Self.score(breakAfterM1: false), width: 2400,
            )
            #expect(doc.systems.count == 1)
            let m1 = try measure(doc, 1)
            #expect(keySignatures(m1).isEmpty)
            #expect(timeSignatures(m1).isEmpty)
            // Regression: the change is still drawn in the header column
            // of its own measure, left of that measure's first notehead.
            let m2 = try measure(doc, 2)
            let key = try #require(keySignatures(m2).first)
            #expect(keySignatures(m2).count == 1)
            #expect(key.flats == 2)
            var firstNoteX = CGFloat.infinity
            for element in m2.elements {
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                    = element, let first = notes.first else { continue }
                firstNoteX = min(firstNoteX, first.origin.x)
            }
            #expect(key.origin.x < firstNoteX)
        }

        @Test("a courtesy of a change to C carries the naturals")
        func courtesyOfAChangeToCMajorCancels() throws {
            let doc = layout(
                Self.score(firstKey: 2, secondKey: 0, timeChange: nil),
            )
            let m1 = try measure(doc, 1)
            let key = try #require(keySignatures(m1).first)
            #expect(key.sharps == 0)
            #expect(key.flats == 0)
            // D major's F♯ C♯, at the treble positions.
            #expect(key.naturals == [4, 1])
            #expect(timeSignatures(m1).isEmpty)
        }

        @Test("every staff is announced, and the time signature once")
        func multiStaffAnnouncesEachKeyAndOneTime() throws {
            let doc = layout(Self.score(clefTypes: ["G", "F"]))
            let m1 = try measure(doc, 1)
            let keys = keySignatures(m1)
            #expect(keys.count == 2)
            #expect(keys.allSatisfy { $0.flats == 2 })
            // Two staves, one shared announcement column: both key
            // signatures at the same x, one time signature per staff at
            // the same x too.
            #expect(Set(keys.map(\.origin.x)).count == 1)
            let times = timeSignatures(m1)
            #expect(times.count == 2)
            #expect(Set(times.map(\.origin.x)).count == 1)
            // The two staves' announcements sit at different heights.
            #expect(Set(keys.map(\.origin.y)).count == 2)
        }

        @Test("breaking reserves the announcement's width")
        func systemDoesNotOverflowTheCourtesy() {
            // No explicit break: the width alone decides where the system
            // ends, so the packer has to reserve the announcement itself.
            let width: CGFloat = 420
            let doc = layout(
                Self.score(breakAfterM1: false), width: width,
            )
            #expect(doc.systems.count >= 2)
            // The scenario has to be live, or "nothing overflows" is
            // trivially true: some system must actually announce.
            var announced = 0
            for sys in doc.systems {
                #expect(sys.size.width <= width + 0.5)
                guard let last = sys.measures.last,
                      last.measureIndex != 2 else { continue }
                for element in last.elements {
                    switch element {
                    case let .keySignature(_, _, _, _, origin),
                         let .timeSignature(_, _, origin):
                        announced += 1
                        #expect(last.origin.x + origin.x <= sys.size.width)
                        // Right of the end barline, per MuseScore's
                        // `EndBarLine, KeySigAnnounce, TimeSigAnnounce`
                        // trailer order.
                        #expect(origin.x > barLineX(last))
                    default:
                        continue
                    }
                }
            }
            #expect(announced > 0)
        }

        /// The measure's own end barline. A measure that announces keeps
        /// it at the end of its CONTENT, not at its right edge.
        private func barLineX(_ m: LayoutMeasure) -> CGFloat {
            var maxX = -CGFloat.infinity
            for element in m.elements {
                guard case let .barLine(_, origin, _) = element
                else { continue }
                maxX = max(maxX, origin.x)
            }
            return maxX
        }

        /// The reservation itself, independent of where a break lands:
        /// a system ending at the measure before a change reserves the
        /// announcement's column; every other measure reserves nothing.
        @Test("the courtesy table reserves only at a change boundary")
        func courtesyTableWidths() {
            let metrics = StaffMetrics(staffSize: 28)
            let table = LayoutEngine.trailingCourtesies(
                staves: Self.score().allStaves.map(\.staff),
                metrics: metrics,
            )
            #expect(table.count == 4)
            #expect(table[0] == nil)
            #expect(table[2] == nil)
            #expect(table[3] == nil)
            let courtesy = table[1]
            #expect(courtesy != nil)
            // Two flats + the 1.5 sp margin, then the time signature's
            // 3 sp column, behind a 0.5 sp gap.
            #expect(courtesy?.width == metrics.sp * (3.5 + 3 + 0.5))
            #expect(courtesy?.keys.count == 1)
            #expect(courtesy?.time?.numerator == 3)
        }
    }
#endif
