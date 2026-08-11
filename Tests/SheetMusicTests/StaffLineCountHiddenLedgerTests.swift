#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Task 13 left two of `LedgerLinePass.insert`'s four call sites in
    /// `LayoutEngine+SystemBuild` without any coverage — the two that
    /// read a fully hidden `Chord(visible: false)`. A literal `-6` left
    /// behind on either would ship green, and the rendered corpus cannot
    /// backstop it: every non-five-line staff in the library is a 1-line
    /// drumset track whose notes never leave the line.
    @Suite("Staff line count — hidden-chord ledger bounds")
    struct StaffLineCountHiddenLedgerTests {
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, *)
        private static func invisibleLedgerCount(
            lineCount: Int, hideSecondNote: Bool,
        ) throws -> Int {
            // G4 is `step` −2 and E4 is −4. On a five-line staff
            // (`firstLedgerStepBelow` −6) neither needs a ledger; on a
            // three-line one (bottom line at `step` 0, first ledger −2)
            // both do.
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(
                    duration: .quarter,
                    notes: [
                        Note(pitch: 67, tpc: 15),
                        Note(pitch: 64, tpc: 18, visible: !hideSecondNote),
                    ],
                    visible: false,
                )),
            ])])
            let score = Score(division: 480, parts: [Part(
                id: "P1",
                instrument: Instrument(id: "perc"),
                staves: [Staff(lineCount: lineCount, measures: [measure])],
            )])
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(
                    wrapToViewWidth: false, showsInvisibleElements: true,
                ),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            var count = 0
            for measure in system.measures {
                for element in measure.invisibleElements {
                    if case .ledgerLine = element { count += 1 }
                }
            }
            return count
        }

        /// Reaches the SECOND call site — the visible notes of a fully
        /// hidden chord (`invisibleNotes: false`).
        @Test("A hidden chord's ledgers follow the staff's line count")
        func hiddenChordLedgerBoundsFollowLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            #expect(try Self.invisibleLedgerCount(
                lineCount: 5, hideSecondNote: false,
            ) == 0)
            #expect(try Self.invisibleLedgerCount(
                lineCount: 3, hideSecondNote: false,
            ) == 2)
        }

        /// Adds the FOURTH call site: marking E4 invisible moves its two
        /// ledgers out of the visible-notes batch and into the
        /// hidden-notehead-inside-a-hidden-chord one, so the total rises
        /// from 2 to 3 only if BOTH sites read the staff's geometry.
        @Test("A hidden notehead inside a hidden chord follows it too")
        func hiddenNoteheadInHiddenChordFollowsLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            #expect(try Self.invisibleLedgerCount(
                lineCount: 5, hideSecondNote: true,
            ) == 0)
            #expect(try Self.invisibleLedgerCount(
                lineCount: 3, hideSecondNote: true,
            ) == 3)
        }
    }
#endif
