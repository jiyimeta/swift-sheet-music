#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// A part's clef is one fact repeated at the left edge of every system,
    /// but the raster detector reads each system independently — so a single
    /// missed or spurious clef costs a whole staff an octave. These cover the
    /// consensus that turns those independent readings into one sequence.
    struct PDFImporterClefConsensusTests {
        private func clef(_ type: String) -> Clef {
            Clef(concertClefType: type)
        }

        @Test func fillsEverySystemWhenTheOnlyReadingsAgree() {
            // The measured failure: 23 systems of a bass staff, the octave
            // clef confident enough to clear the threshold in exactly one.
            var readings = [Clef?](repeating: nil, count: 23)
            readings[7] = clef("F8va")
            let resolved = PDFImporter.consensusInitialClefs(perSystem: readings)
            #expect(resolved.allSatisfy { $0?.concertClefType == "F8va" })
        }

        @Test func leavesASlotWithNoReadingAlone() {
            // Nothing detected anywhere is not evidence for any clef: the
            // caller's own default has to stay in charge.
            let resolved = PDFImporter.consensusInitialClefs(
                perSystem: [Clef?](repeating: nil, count: 5),
            )
            #expect(resolved.allSatisfy { $0 == nil })
        }

        @Test func replacesAnIsolatedOutlierBetweenAgreeingNeighbors() {
            // The other measured failure: one spurious plain clef outranking
            // the true octave one in a single system.
            let readings: [Clef?] = [
                clef("G8vb"), clef("G8vb"), clef("G"), clef("G8vb"), clef("G8vb"),
            ]
            let resolved = PDFImporter.consensusInitialClefs(perSystem: readings)
            #expect(resolved.map { $0?.concertClefType } == Array(
                repeating: "G8vb", count: 5,
            ))
        }

        @Test func keepsAGenuineMidScoreClefChange() {
            // A real change is a RUN, not an outlier: both sides of the
            // boundary disagree, so neither position is smoothed away.
            let readings: [Clef?] = [
                clef("G"), clef("G"), clef("G"), clef("F"), clef("F"), clef("F"),
            ]
            let resolved = PDFImporter.consensusInitialClefs(perSystem: readings)
            #expect(resolved.map { $0?.concertClefType }
                == ["G", "G", "G", "F", "F", "F"])
        }

        @Test func fillsAGapInsideARunButNotAcrossAChange() {
            // A hole between two agreeing systems is filled; a hole at a
            // boundary, where the neighbors disagree, is left for the
            // running-state default rather than guessed at.
            let readings: [Clef?] = [
                clef("G"), nil, clef("G"), nil, clef("F"), clef("F"),
            ]
            let resolved = PDFImporter.consensusInitialClefs(perSystem: readings)
            #expect(resolved.map { $0?.concertClefType }
                == ["G", "G", "G", nil, "F", "F"])
        }

        @Test func singleSystemScoreIsUntouched() {
            // A one-system document (a wide single-page export) has no second
            // opinion to offer, so consensus must not manufacture one.
            let resolved = PDFImporter.consensusInitialClefs(
                perSystem: [clef("G8vb")],
            )
            #expect(resolved.map { $0?.concertClefType } == ["G8vb"])
        }
    }
#endif
