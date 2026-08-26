@testable import SheetMusicCore
import Testing

@Suite("InsertMeasure")
struct InsertMeasureTests {
    private func twoBarScore() -> Score {
        // Grand staff, 2 measures, signatures on bar 1 — built via the Task 1 factory so the shape is canonical.
        Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [.init(
                instrumentID: "piano",
                staves: [.init(clefType: "G"), .init(clefType: "F")],
            )],
            concertKey: 1, timeNumerator: 4, timeDenominator: 4,
            tempoBPM: 120, measureCount: 2,
        ))
    }

    @Test("append grows every staff and systemMeasures in step")
    func append() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 2).apply(to: &score)
        #expect(score.systemMeasures.count == 3)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 3)
            #expect(staff.measures[2].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("insert at 0 moves the leading signatures into the new first bar")
    func insertAtZero() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let newFirst = staff.measures[0].voices[0].elements
            #expect(newFirst[0] == .keySignature(KeySignature(concertKey: 1)))
            #expect(newFirst[1] == .timeSignature(TimeSignature(numerator: 4, denominator: 4)))
            #expect(newFirst[2].isMeasureRest)
            // The displaced old first bar keeps only its rest.
            #expect(staff.measures[1].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("mid-piece insert leaves neighboring signatures attached to their measures")
    func insertMiddle() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 1).apply(to: &score)
        for staff in score.parts[0].staves {
            #expect(staff.measures[0].voices[0].elements.count == 3) // sigs stay on bar 1
            #expect(staff.measures[1].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("apply returns an inverse that restores the exact score")
    func inverse() throws {
        for index in [0, 1, 2] {
            var score = twoBarScore()
            let original = score
            let inverse = try InsertMeasure(measureIndex: index).apply(to: &score)
            #expect(score != original)
            _ = try inverse.apply(to: &score)
            #expect(score == original, "index \(index)")
        }
    }

    @Test("out-of-range index refuses")
    func outOfRange() {
        var score = twoBarScore()
        #expect(throws: SheetMusicError.self) {
            try InsertMeasure(measureIndex: 5).apply(to: &score)
        }
    }

    @Test("insertion stretches a spanner's stored offset when it crosses the boundary")
    func spannerOffsetStretches() throws {
        var score = twoBarScore()
        let spanner = Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1)
        score.parts[0].staves[0].measures[0].voices[0].elements.append(.spanner(spanner))

        let inverse = try InsertMeasure(measureIndex: 1).apply(to: &score)

        let stretched = score.parts[0].staves[0].measures[0].voices[0].elements.last
        guard case let .spanner(stretchedSpanner) = stretched else {
            Issue.record("expected a spanner element")
            return
        }
        #expect(stretchedSpanner.nextMeasuresOffset == 2)

        _ = try inverse.apply(to: &score)
        let restored = score.parts[0].staves[0].measures[0].voices[0].elements.last
        guard case let .spanner(restoredSpanner) = restored else {
            Issue.record("expected a spanner element")
            return
        }
        #expect(restoredSpanner.nextMeasuresOffset == 1)
    }

    @Test("insert at 0 shifts tuplet ranges in the displaced bar")
    func insertAtZeroShiftsTuplets() throws {
        var score = twoBarScore()
        let members: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
        ]
        // Bar 0 was [key, time, rest]; replace the rest (index 2) with 3 triplet members.
        score.parts[0].staves[0].measures[0].voices[0].elements.replaceSubrange(2 ..< 3, with: members)
        score.parts[0].staves[0].measures[0].voices[0].tuplets = [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4),
        ]
        let original = score

        let inverse = try InsertMeasure(measureIndex: 0).apply(to: &score)

        // The 2-element signature prefix was removed from this bar (now at measure index 1), so the
        // tuplet's indices must shift down by 2 — asserted right after apply, not only after the round trip,
        // since the bug this guards against is symmetric and would otherwise cancel out invisibly.
        #expect(score.parts[0].staves[0].measures[1].voices[0].tuplets ==
            [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)])

        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }
}
