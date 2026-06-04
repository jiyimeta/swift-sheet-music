@testable import SheetMusicCore
import Testing

struct ScoreDisplayTransformsTests {
    // MARK: - Fixtures

    private static func instrument(id: String) -> Instrument {
        Instrument(id: id, longName: id)
    }

    /// Three-part score: part 0 has 1 staff, part 1 has 2 staves, part 2 has 1 staff.
    private func makeScore() -> Score {
        let inst = Self.instrument(id: "x")
        return Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [
                Staff(measures: []),
            ]),
            Part(id: "p1", instrument: inst, staves: [
                Staff(measures: []),
                Staff(measures: []),
            ]),
            Part(id: "p2", instrument: inst, staves: [
                Staff(measures: []),
            ]),
        ])
    }

    /// Score with a bracket spanning both staves of a two-staff part.
    private func makeScoreWithBracket() -> Score {
        let inst = Self.instrument(id: "piano")
        let bracket = BracketItem(type: .brace, span: 2)
        var treble = Staff(measures: [])
        treble.brackets = [bracket]
        let bass = Staff(measures: [])
        return Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [treble, bass]),
        ])
    }

    /// Score where a staff's first measure/voice/element is an explicit Clef.
    private func makeScoreWithExplicitClef(clefType: String) -> Score {
        let inst = Self.instrument(id: "inst")
        let clefElement = VoiceElement.clef(Clef(concertClefType: clefType))
        let voice = Voice(elements: [clefElement])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        return Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
    }

    // MARK: - filtered(hidingStaves:)

    @Test func filterEmptySetReturnsEqualPartCount() {
        let score = makeScore()
        let filtered = score.filtered(hidingStaves: [])
        #expect(filtered.parts.count == score.parts.count)
    }

    @Test func filterHidingAllStavesOfPartDropsThatPart() {
        let score = makeScore()
        // Part 1 has staves at (1,0) and (1,1). Hide both.
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ]
        let filtered = score.filtered(hidingStaves: hidden)
        // Parts 0 and 2 survive; part 1 is gone.
        #expect(filtered.parts.count == 2)
        #expect(filtered.parts[0].id == "p0")
        #expect(filtered.parts[1].id == "p2")
    }

    @Test func filterHidingOneStaffOfTwoRetainsOtherStaff() {
        let score = makeScore()
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ]
        let filtered = score.filtered(hidingStaves: hidden)
        // Part 1 still present with 1 staff.
        #expect(filtered.parts.count == 3)
        #expect(filtered.parts[1].staves.count == 1)
    }

    @Test func filterRebasesBracketSpanOverSurvivingStaves() {
        let score = makeScoreWithBracket()
        // Hide the bass staff (index 1); the brace should shrink from span=2 to span=1.
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
        ]
        let filtered = score.filtered(hidingStaves: hidden)
        #expect(filtered.parts.count == 1)
        #expect(filtered.parts[0].staves.count == 1)
        // The surviving treble staff should carry a rebased brace with span=1.
        let brackets = filtered.parts[0].staves[0].brackets
        #expect(brackets.count == 1)
        #expect(brackets[0].span == 1)
    }

    @Test func filterDropsBracketWhenAllStavesInSpanAreHidden() {
        let score = makeScoreWithBracket()
        // Hide both staves — the whole part drops and no brackets survive.
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
        ]
        let filtered = score.filtered(hidingStaves: hidden)
        #expect(filtered.parts.isEmpty)
    }

    @Test func filterReanchorsBracketOnFirstSurvivingStaffWhenAnchorHidden() {
        let score = makeScoreWithBracket()
        // Hide the treble (original anchor); bass survives and the bracket is re-anchored on it.
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
        ]
        let filtered = score.filtered(hidingStaves: hidden)
        #expect(filtered.parts[0].staves.count == 1)
        // The bracket is re-anchored on the surviving bass staff with span reduced to 1.
        let brackets = filtered.parts[0].staves[0].brackets
        #expect(brackets.count == 1)
        #expect(brackets[0].span == 1)
    }

    // MARK: - applying(clefOverrides:)

    @Test func clefOverrideEmptyMapReturnsEqualScore() {
        let score = makeScore()
        let result = score.applying(clefOverrides: [:])
        #expect(result == score)
    }

    @Test func clefOverrideSetsDefaultClefTypeWhenNoExplicitClef() {
        let score = makeScore()
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [addr: "F"])
        #expect(result.parts[0].staves[0].defaultClefType == "F")
    }

    @Test func clefOverrideRewritesExplicitMeasure0Clef() {
        let score = makeScoreWithExplicitClef(clefType: "G")
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [addr: "F"])
        // The first element should now be a clef with concertClefType "F".
        guard case let .clef(clef) = result.parts[0].staves[0].measures[0].voices[0].elements[0] else {
            Issue.record("Expected a .clef element at position 0")
            return
        }
        #expect(clef.concertClefType == "F")
        #expect(clef.transposingClefType == nil)
    }

    @Test func clefOverrideOutOfRangeAddressIsSkipped() {
        let score = makeScore()
        let outOfRange = StaffAddress(partIndex: 99, staffIndexInPart: 0)
        // Must not crash; score should remain unchanged.
        let result = score.applying(clefOverrides: [outOfRange: "F"])
        #expect(result == score)
    }
}
