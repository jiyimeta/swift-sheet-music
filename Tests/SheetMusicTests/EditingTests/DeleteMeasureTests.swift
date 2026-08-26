@testable import SheetMusicCore
import Testing

@Suite("DeleteMeasure")
struct DeleteMeasureTests {
    private func threeBarScore() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano",
            staves: [.init(clefType: "G"), .init(clefType: "F")],
            concertKey: -2, timeNumerator: 6, timeDenominator: 8,
            tempoBPM: 120, measureCount: 3,
        ))
    }

    @Test("delete shrinks every staff and systemMeasures in step")
    func deleteMiddle() throws {
        var score = threeBarScore()
        _ = try DeleteMeasure(measureIndex: 1).apply(to: &score)
        #expect(score.systemMeasures.count == 2)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 2)
        }
    }

    @Test("deleting bar 0 carries the signatures onto the new first bar")
    func deleteFirst() throws {
        var score = threeBarScore()
        _ = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: -2)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 6, denominator: 8)))
            #expect(first[2].isMeasureRest)
        }
    }

    @Test("a first bar with its own signature kind keeps it, in canonical clef/key/time order")
    func deleteFirstWithOwnKey() throws {
        var score = threeBarScore()
        // Give bar 1 its own key change; deleting bar 0 must keep it and only inherit the time signature —
        // ahead of it, per MuseScore's structural clef→key→time order, not wherever a blind prepend lands it.
        for staffIndex in score.parts[0].staves.indices {
            score.parts[0].staves[staffIndex].measures[1].voices[0].elements
                .insert(.keySignature(KeySignature(concertKey: 3)), at: 0)
        }
        _ = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: 3)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 6, denominator: 8)))
            #expect(first[2].isMeasureRest)
        }
    }

    @Test("deleting bar 0 shifts tuplet ranges in the incoming bar that inherits signatures")
    func deleteFirstShiftsTuplets() throws {
        var score = threeBarScore()
        let members: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
        ]
        // Bar 1 (the incoming first bar once bar 0 is deleted) was [rest]; give it 3 triplet members instead.
        for staffIndex in score.parts[0].staves.indices {
            score.parts[0].staves[staffIndex].measures[1].voices[0].elements.replaceSubrange(0 ..< 1, with: members)
            score.parts[0].staves[staffIndex].measures[1].voices[0].tuplets = [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
            ]
        }
        let original = score

        let inverse = try DeleteMeasure(measureIndex: 0).apply(to: &score)

        // The incoming bar inherited [key, time] (2 elements) prepended ahead of its tuplet members, so the
        // tuplet's indices must shift up by 2 — asserted right after apply, not only after the round trip.
        for staff in score.parts[0].staves {
            #expect(staff.measures[0].voices[0].tuplets ==
                [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)])
        }

        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("undo restores a spanner that ended exactly at the deleted measure")
    func deleteEndpointSpannerUndo() throws {
        var score = threeBarScore()
        // Anchored at bar 0 with offset 1, this spanner's span ends exactly at bar 1 — the boundary the
        // generic insertion predicate can't distinguish from "never touched this spanner" once the delete
        // has already shrunk the offset.
        let spanner = Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1)
        score.parts[0].staves[0].measures[0].voices[0].elements.append(.spanner(spanner))
        let original = score

        let inverse = try DeleteMeasure(measureIndex: 1).apply(to: &score)
        _ = try inverse.apply(to: &score)

        #expect(score == original)
    }

    @Test("delete → undo is exact for a score whose systemMeasures never tracked measures")
    func deleteUndoWithEmptySystemMeasures() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        #expect(score.systemMeasures.isEmpty)
        let original = score

        let inverse = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        #expect(score.systemMeasures.isEmpty)

        _ = try inverse.apply(to: &score)
        #expect(score.systemMeasures.isEmpty)
        #expect(score == original)
    }

    @Test("inverse restores the exact score, including the bar-0 signature merge")
    func inverse() throws {
        for index in [0, 1, 2] {
            var score = threeBarScore()
            let original = score
            let inverse = try DeleteMeasure(measureIndex: index).apply(to: &score)
            _ = try inverse.apply(to: &score)
            #expect(score == original, "index \(index)")
        }
    }

    @Test("deleting the only measure refuses")
    func lastMeasure() {
        var score = Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        #expect(throws: SheetMusicError.self) {
            try DeleteMeasure(measureIndex: 0).apply(to: &score)
        }
    }

    @Test("delete → undo → redo converges")
    func redoConverges() throws {
        var score = threeBarScore()
        let afterDeleteInverse = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        let afterDelete = score
        let redo = try afterDeleteInverse.apply(to: &score) // undo
        _ = try redo.apply(to: &score) // redo
        #expect(score == afterDelete)
    }
}
