import SheetMusicCore
import Testing

@Suite("Score.activeKey")
struct ScoreActiveKeyTests {
    private static func staffWith(
        keys: [(measureIdx: Int, key: Int)]
    ) -> StaffContent {
        // Build 4 measures. Each gets a key-sig prefix at the listed
        // indexes; the rest of the measure is a single whole rest so
        // the score parses as valid.
        var measures: [Measure] = []
        for i in 0 ..< 4 {
            var elements: [VoiceElement] = []
            if let entry = keys.first(where: { $0.measureIdx == i }) {
                elements.append(.keySignature(
                    KeySignature(concertKey: entry.key)))
            }
            elements.append(.rest(duration: .whole))
            measures.append(Measure(voices: [Voice(elements: elements)]))
        }
        return StaffContent(id: 1, measures: measures)
    }

    @Test("No key declared → 0 (C major)")
    func defaultIsZero() {
        let score = Score(
            division: 480,
            staves: [Self.staffWith(keys: [])]
        )
        #expect(score.activeKey(staffIndex: 0, measureIndex: 0) == 0)
        #expect(score.activeKey(staffIndex: 0, measureIndex: 3) == 0)
    }

    @Test("Key declared in measure 0 carries forward")
    func declaredAtStart() {
        let score = Score(
            division: 480,
            staves: [Self.staffWith(keys: [(0, -4)])]
        )
        #expect(score.activeKey(staffIndex: 0, measureIndex: 0) == -4)
        #expect(score.activeKey(staffIndex: 0, measureIndex: 3) == -4)
    }

    @Test("Mid-piece key change takes effect from its measure forward")
    func midPieceChange() {
        let score = Score(
            division: 480,
            staves: [Self.staffWith(keys: [(0, -4), (2, 2)])]
        )
        #expect(score.activeKey(staffIndex: 0, measureIndex: 0) == -4)
        #expect(score.activeKey(staffIndex: 0, measureIndex: 1) == -4)
        #expect(score.activeKey(staffIndex: 0, measureIndex: 2) == 2)
        #expect(score.activeKey(staffIndex: 0, measureIndex: 3) == 2)
    }

    @Test("Out-of-range staffIndex falls back to 0")
    func outOfRangeStaff() {
        let score = Score(
            division: 480,
            staves: [Self.staffWith(keys: [(0, -4)])]
        )
        #expect(score.activeKey(staffIndex: 5, measureIndex: 0) == 0)
    }
}
