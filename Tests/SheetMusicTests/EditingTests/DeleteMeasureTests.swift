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

    @Test("a first bar with its own signature kind keeps it over the deleted one")
    func deleteFirstWithOwnKey() throws {
        var score = threeBarScore()
        // Give bar 1 its own key change; deleting bar 0 must keep it and only inherit the time signature.
        for staffIndex in score.parts[0].staves.indices {
            score.parts[0].staves[staffIndex].measures[1].voices[0].elements
                .insert(.keySignature(KeySignature(concertKey: 3)), at: 0)
        }
        _ = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let first = staff.measures[0].voices[0].elements
            #expect(first.contains(.keySignature(KeySignature(concertKey: 3))))
            #expect(!first.contains(.keySignature(KeySignature(concertKey: -2))))
            #expect(first.contains(.timeSignature(TimeSignature(numerator: 6, denominator: 8))))
        }
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
