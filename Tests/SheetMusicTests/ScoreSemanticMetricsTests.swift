#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    import Testing

    struct ScoreSemanticMetricsTests {
        /// One part, one staff; each inner array is one measure of quarter
        /// chords at the given MIDI pitches (a nil pitch = quarter rest).
        static func makeScore(
            _ measures: [[Int?]], tieForwardAt: (measure: Int, index: Int)? = nil,
        ) -> Score {
            var builtMeasures: [Measure] = []
            for (mi, pitches) in measures.enumerated() {
                var elements: [VoiceElement] = []
                if mi == 0 {
                    elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                }
                for (ei, p) in pitches.enumerated() {
                    if let p {
                        var note = Note(pitch: p, tpc: 14)
                        if let tie = tieForwardAt, tie.measure == mi, tie.index == ei {
                            note.tieForward = 1
                        }
                        elements.append(.chord(Chord(duration: .quarter, notes: [note])))
                    } else {
                        elements.append(.chord(Chord(duration: .quarter, notes: [])))
                    }
                }
                builtMeasures.append(Measure(voices: [Voice(elements: elements)]))
            }
            let staff = Staff(measures: builtMeasures)
            let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
            return Score(division: 480, parts: [part])
        }

        @Test func identicalScoresScoreEverything100Percent() {
            let a = Self.makeScore([[60, 62, 64, 65], [67, 69, 71, 72]])
            let pitch = ScoreSemanticMetrics.measureAlignedPitchMatch(scoreA: a, scoreB: a)
            #expect(pitch.pos.m == 8)
            #expect(pitch.pos.c == 8)
            #expect(pitch.set.m == pitch.set.c)
            let dur = ScoreSemanticMetrics.measureAlignedDurationMatch(scoreA: a, scoreB: a)
            #expect(dur.match.m == dur.match.c)
            #expect(dur.match.c > 0)
        }

        @Test func onePitchOffCosts1Of8() {
            let a = Self.makeScore([[60, 62, 64, 65], [67, 69, 71, 72]])
            let b = Self.makeScore([[60, 62, 64, 65], [67, 69, 71, 73]])
            let pitch = ScoreSemanticMetrics.measureAlignedPitchMatch(scoreA: a, scoreB: b)
            #expect(pitch.pos.m == 7)
            #expect(pitch.pos.c == 8)
        }

        @Test func tieRecallCountsMissingTieAsFalseNegative() {
            let a = Self.makeScore([[60, 60, 62, 64]], tieForwardAt: (0, 0))
            let b = Self.makeScore([[60, 60, 62, 64]]) // tie lost
            let tie = ScoreSemanticMetrics.measureAlignedTieMatch(scoreA: a, scoreB: b)
            #expect(tie.aTied == 1)
            #expect(tie.bTied == 0)
            #expect(tie.fn == 1)
            #expect(tie.tp == 0)
            let perfect = ScoreSemanticMetrics.measureAlignedTieMatch(scoreA: a, scoreB: a)
            #expect(perfect.tp == 1)
            #expect(perfect.fn == 0)
        }

        @Test func contentTotalsSeparateNotesAndRests() {
            let a = Self.makeScore([[60, nil, 64, nil]])
            let t = ScoreSemanticMetrics.contentTotals(a)
            #expect(t.notes == 2)
            #expect(t.rests == 2)
        }

        @Test func alignNotefulPartsDropsEmptyParts() {
            var a = Self.makeScore([[60, 62, 64, 65]])
            let emptyStaff = Staff(measures: [Measure(voices: [Voice(elements: [])])])
            a.parts.append(Part(id: "2", instrument: Instrument(id: "y"), staves: [emptyStaff]))
            let b = Self.makeScore([[60, 62, 64, 65]])
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: a, scoreB: b)
            #expect(aligned.scoreA.parts.count == 1)
            #expect(aligned.scoreB.parts.count == 1)
            #expect(aligned.partLossNotes == 0)
        }

        @Test func pctStrFormatsAndHandlesZeroDenominator() {
            #expect(ScoreSemanticMetrics.pctStr(3, 4) == "75%")
            #expect(ScoreSemanticMetrics.pctStr(0, 0) == "n/a")
        }

        @Test func summaryRowCarriesTheGreppableFields() {
            let a = Self.makeScore([[60, 62, 64, 65]])
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: a, scoreB: a)
            let row = ScoreSemanticMetrics.summaryRow(
                tag: "[t]", scoreA: a, scoreB: a,
                pdfRecovered: true, aligned: aligned, hiddenLoss: 0,
            )
            #expect(row.contains("[t][SUMMARY]"))
            #expect(row.contains("pitch%=100%"))
            #expect(row.contains("dur%=100%"))
            #expect(row.contains("measuresA=1 measuresB=1"))
            #expect(row.contains("notesA=4 notesB=4"))
        }

        @Test func firstDivergenceReportsTheMismatchedMeasureWithWindow() throws {
            let a = Self.makeScore([[60, 62, 64, 65], [67, 69, 71, 72], [60, 60, 60, 60]])
            let b = Self.makeScore([[60, 62, 64, 65], [67, 69, 71, 73], [60, 60, 60, 60]])
            let report = ScoreSemanticMetrics.firstDivergenceReport(scoreA: a, scoreB: b, window: 1)
            let text = try #require(report)
            #expect(text.contains("measure 1"))
            #expect(text.contains("A[0]")) // window includes the neighbor
            #expect(text.contains("A[2]"))
            #expect(ScoreSemanticMetrics.firstDivergenceReport(scoreA: a, scoreB: a, window: 1) == nil)
        }
    }
#endif
