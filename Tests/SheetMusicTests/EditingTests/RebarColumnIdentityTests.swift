@testable import SheetMusicCore
import Testing

@Suite("Rebar column identity")
struct RebarColumnIdentityTests {
    @Test("a growing run keeps the trailing irregular column's identity")
    func growingRunBeforeIrregularBar() throws {
        try Self.checkRebar(
            measureCount: 3, irregularIndex: 2, numerator: 2,
            expectedSources: [0, 1, nil, nil, 2],
        )
    }

    @Test("a shrinking run keeps the trailing irregular column's identity")
    func shrinkingRunBeforeIrregularBar() throws {
        try Self.checkRebar(
            measureCount: 4, irregularIndex: 3, numerator: 6,
            expectedSources: [0, 1, 3],
        )
    }

    @Test("runs on both sides of an irregular bar retain their own source identities")
    func growingRunsAroundIrregularBar() throws {
        try Self.checkRebar(
            measureCount: 5, irregularIndex: 2, numerator: 2,
            expectedSources: [0, 1, nil, nil, 2, 3, 4, nil, nil],
        )
    }

    @Test("a regular region keeps old column identities before minting its growth")
    func regularRegionIdentityPin() throws {
        try Self.checkRebar(
            measureCount: 2, irregularIndex: nil, numerator: 2,
            expectedSources: [0, 1, nil, nil],
        )
    }
}

extension RebarColumnIdentityTests {
    private static func checkRebar(
        measureCount: Int, irregularIndex: Int?, numerator: Int, expectedSources: [Int?],
    ) throws {
        let original = fixture(measureCount: measureCount, irregularIndex: irregularIndex)
        let session = ScoreEditSession(score: original)
        let before = session.score
        let beforeEIDs = laneEIDs(before)
        try #require(before.systemMeasures.count == MeasureStructure.measureCount(of: before))

        try #require(session.apply(.setTimeSignature(measureIndex: 0, numerator: numerator, denominator: 4)))
        let after = session.score
        let afterEIDs = laneEIDs(after)
        try #require(afterEIDs.count == expectedSources.count)
        #expect(Set(afterEIDs).count == afterEIDs.count)
        #expect(after.systemMeasures.count == MeasureStructure.measureCount(of: after))
        for (index, source) in expectedSources.enumerated() {
            if let source {
                #expect(afterEIDs[index] == beforeEIDs[source])
            } else {
                #expect(!beforeEIDs.contains(afterEIDs[index]))
            }
        }
        if let irregularIndex {
            let destination = try #require(expectedSources.firstIndex(of: irregularIndex))
            #expect(after.systemMeasures[destination] == before.systemMeasures[irregularIndex])
        }

        try #require(session.undo())
        #expect(laneEIDs(session.score) == beforeEIDs)
        #expect(session.score == before)
        try #require(session.redo())
        #expect(laneEIDs(session.score) == afterEIDs)
        #expect(session.score == after)
    }

    private static func laneEIDs(_ score: Score) -> [EID] {
        let lane = score.systemMeasures
        return (0 ..< lane.count).map { lane.eid(at: $0) }
    }

    private static func fixture(measureCount: Int, irregularIndex: Int?) -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            concertKey: 0, measureCount: measureCount,
        ))
        if let irregularIndex {
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[irregularIndex].actualLength = Fraction(numerator: 1, denominator: 4)
                    staffValue.measures[irregularIndex].irregular = true
                }
            }
            score.systemMeasures.updateValue(at: irregularIndex) {
                $0.elements = [PositionedSystemElement(
                    position: .start, element: .tempo(Tempo(beatsPerSecond: 3)),
                )]
            }
        }
        return score
    }
}
