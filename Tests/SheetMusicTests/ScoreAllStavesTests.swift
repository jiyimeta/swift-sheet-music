@testable import SheetMusicCore
import Testing

@Suite struct ScoreAllStavesTests {
    private static func minimalInstrument(id: String) -> Instrument {
        Instrument(id: id, longName: id)
    }

    private func mkScore() -> Score {
        let inst = Self.minimalInstrument(id: "x")
        return Score(division: 480, parts: [
            Part(id: "1", instrument: inst, staves: [Staff(measures: [])]),
            Part(id: "2", instrument: inst, staves: [
                Staff(measures: []),
                Staff(measures: []),
            ]),
            Part(id: "3", instrument: inst, staves: [Staff(measures: [])]),
        ])
    }

    @Test func displayOrder() {
        let s = mkScore()
        let addrs = s.allStaves.map(\.address)
        #expect(addrs == [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
            StaffAddress(partIndex: 2, staffIndexInPart: 0),
        ])
        #expect(s.totalStaffCount == 4)
    }

    @Test func subscriptResolves() {
        let s = mkScore()
        #expect(s[StaffAddress(partIndex: 1, staffIndexInPart: 1)] != nil)
        #expect(s[StaffAddress(partIndex: 1, staffIndexInPart: 5)] == nil)
        #expect(s[StaffAddress(partIndex: 99, staffIndexInPart: 0)] == nil)
        #expect(s.part(at: StaffAddress(partIndex: 0, staffIndexInPart: 0))?.id == "1")
    }
}
