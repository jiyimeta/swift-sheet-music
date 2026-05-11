import SheetMusicCore
import Testing

@Suite("Score.activeKey")
struct ScoreActiveKeyTests {
    private static func staffWith(
        keys: [(measureIdx: Int, key: Int)],
    ) -> Staff {
        // Build 4 measures. Each gets a key-sig prefix at the listed
        // indexes; the rest of the measure is a single whole rest so
        // the score parses as valid.
        var measures: [Measure] = []
        for i in 0 ..< 4 {
            var elements: [VoiceElement] = []
            if let entry = keys.first(where: { $0.measureIdx == i }) {
                elements.append(.keySignature(
                    KeySignature(concertKey: entry.key),
                ))
            }
            elements.append(.rest(duration: .whole))
            measures.append(Measure(voices: [Voice(elements: elements)]))
        }
        return Staff(measures: measures)
    }

    private static func scoreWith(keys: [(measureIdx: Int, key: Int)]) -> Score {
        let staff = staffWith(keys: keys)
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    @Test("No key declared → 0 (C major)")
    func defaultIsZero() {
        let score = Self.scoreWith(keys: [])
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(score.activeKey(staff: addr, measureIndex: 0) == 0)
        #expect(score.activeKey(staff: addr, measureIndex: 3) == 0)
    }

    @Test("Key declared in measure 0 carries forward")
    func declaredAtStart() {
        let score = Self.scoreWith(keys: [(0, -4)])
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(score.activeKey(staff: addr, measureIndex: 0) == -4)
        #expect(score.activeKey(staff: addr, measureIndex: 3) == -4)
    }

    @Test("Mid-piece key change takes effect from its measure forward")
    func midPieceChange() {
        let score = Self.scoreWith(keys: [(0, -4), (2, 2)])
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(score.activeKey(staff: addr, measureIndex: 0) == -4)
        #expect(score.activeKey(staff: addr, measureIndex: 1) == -4)
        #expect(score.activeKey(staff: addr, measureIndex: 2) == 2)
        #expect(score.activeKey(staff: addr, measureIndex: 3) == 2)
    }

    @Test("Out-of-range staff falls back to 0")
    func outOfRangeStaff() {
        let score = Self.scoreWith(keys: [(0, -4)])
        let bogus = StaffAddress(partIndex: 5, staffIndexInPart: 0)
        #expect(score.activeKey(staff: bogus, measureIndex: 0) == 0)
    }
}
