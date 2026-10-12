@testable import SheetMusicCore
import SheetMusicFoundation
import Testing

/// The tables a planner reads once per walk must give exactly the answers of the score lookups they stand in for —
/// they exist to save the per-element rescans, never to change an answer.
@Suite("Staff tables")
struct StaffTablesTests {
    private static let upper = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let lower = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    private static let absent = StaffAddress(partIndex: 3, staffIndexInPart: 0)

    private static func bar(_ elements: [VoiceElement], actualLength: Fraction? = nil) -> Measure {
        Measure(voices: [Voice(elements: elements)], actualLength: actualLength)
    }

    /// Key and meter changes mid-staff, a short bar, a bar with no voice at all, and a second staff that declares
    /// neither key nor a later meter.
    private static func score() -> Score {
        let rest = VoiceElement.rest(duration: .quarter)
        let threeFour = VoiceElement.timeSignature(TimeSignature(numerator: 3, denominator: 4))
        let sixEight = VoiceElement.timeSignature(TimeSignature(numerator: 6, denominator: 8))
        let upper = Staff(measures: [
            bar([threeFour, .keySignature(KeySignature(concertKey: 2)), rest, rest, rest]),
            bar([rest, rest, rest]),
            bar([.keySignature(KeySignature(concertKey: -3)), sixEight, .rest(duration: .measure)]),
            bar([rest], actualLength: Fraction(numerator: 1, denominator: 4)),
            Measure(voices: []),
            bar([.keySignature(KeySignature(concertKey: 5)), .rest(duration: .measure)]),
        ])
        let lower = Staff(measures: (0 ..< 6).map { index in
            bar(index == 0 ? [.timeSignature(TimeSignature(numerator: 2, denominator: 4)), rest, rest] : [rest, rest])
        })
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [upper, lower])])
    }

    @Test("every bar's length matches effectiveMeasureDuration, past the staff's end and off the score included")
    func durations() {
        let score = Self.score()
        let built = MeasureDurationTable(score, staves: [Self.upper, Self.lower, Self.absent])
        let fallingBack = MeasureDurationTable(score, staves: [])
        for staff in [Self.upper, Self.lower, Self.absent] {
            for measure in 0 ... 8 {
                let expected = score.effectiveMeasureDuration(at: staff, measureIndex: measure)
                #expect(built.duration(at: staff, measureIndex: measure) == expected, "\(staff) bar \(measure)")
                #expect(fallingBack.duration(at: staff, measureIndex: measure) == expected, "\(staff) bar \(measure)")
            }
        }
        #expect(built.agrees(with: score))
    }

    @Test("every bar's key matches activeKey, past the staff's end and off the score included")
    func keys() {
        let score = Self.score()
        let built = ActiveKeyTable(score, staves: [Self.upper, Self.lower, Self.absent])
        let fallingBack = ActiveKeyTable(score, staves: [])
        for staff in [Self.upper, Self.lower, Self.absent] {
            for measure in 0 ... 8 {
                let expected = score.activeKey(staff: staff, measureIndex: measure)
                #expect(built.key(staff: staff, measureIndex: measure) == expected, "\(staff) bar \(measure)")
                #expect(fallingBack.key(staff: staff, measureIndex: measure) == expected, "\(staff) bar \(measure)")
            }
        }
        #expect(built.agrees(with: score))
    }

    @Test("a table notices a score whose meter or key moved")
    func disagreement() {
        let score = Self.score()
        var remetered = score
        remetered[VoiceElementID(staff: Self.lower, measureIndex: 0, voiceIndex: 0, elementIndex: 0)] =
            .timeSignature(TimeSignature(numerator: 3, denominator: 4))
        #expect(!MeasureDurationTable(score, staves: [Self.lower]).agrees(with: remetered))

        var rekeyed = score
        rekeyed[VoiceElementID(staff: Self.upper, measureIndex: 1, voiceIndex: 0, elementIndex: 0)] =
            .keySignature(KeySignature(concertKey: 1))
        #expect(!ActiveKeyTable(score, staves: [Self.upper]).agrees(with: rekeyed))
    }
}
