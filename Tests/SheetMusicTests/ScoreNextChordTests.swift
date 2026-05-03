import SheetMusicCore
import Testing

@Suite("Score.nextChord")
struct ScoreNextChordTests {
    private static func chord(_ p: Int = 60) -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: p, tpc: 14)]
        ))
    }

    private static let restQ: VoiceElement = .rest(
        duration: .quarter)

    @Test("returns the next chord in the same measure")
    func sameMeasure() {
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
            Staff(measures: [
                Measure(voices: [Voice(elements: [
                    Self.chord(60), Self.chord(62), Self.chord(64),
                ])]),
            ]),
        ])])
        let here = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let next = score.nextChord(after: here)
        #expect(next?.elementIndex == 1)
        #expect(next?.measureIndex == 0)
    }

    @Test("skips non-chord elements (rest, barline, etc.)")
    func skipsNonChord() {
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
            Staff(measures: [
                Measure(voices: [Voice(elements: [
                    Self.chord(60),
                    Self.restQ,
                    .barLine(BarLine()),
                    Self.chord(62),
                ])]),
            ]),
        ])])
        let here = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let next = score.nextChord(after: here)
        #expect(next?.elementIndex == 3)
    }

    @Test("crosses measure boundaries")
    func crossesMeasures() {
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
            Staff(measures: [
                Measure(voices: [Voice(elements: [Self.chord(60)])]),
                Measure(voices: [Voice(elements: [Self.restQ, Self.chord(62)])]),
            ]),
        ])])
        let here = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let next = score.nextChord(after: here)
        #expect(next?.measureIndex == 1)
        #expect(next?.elementIndex == 1)
    }

    @Test("returns nil at the end of the staff")
    func endOfStaff() {
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
            Staff(measures: [
                Measure(voices: [Voice(elements: [Self.chord(60)])]),
            ]),
        ])])
        let here = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        #expect(score.nextChord(after: here) == nil)
    }

    @Test("respects the voice index — only walks the same voice")
    func sameVoiceOnly() {
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
            Staff(measures: [
                Measure(voices: [
                    Voice(elements: [Self.chord(60), Self.restQ]),
                    Voice(elements: [Self.chord(72), Self.chord(74)]),
                ]),
            ]),
        ])])
        let here = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
        )
        let next = score.nextChord(after: here)
        // Next chord in voice 0 is at elementIndex 0 only (restQ follows);
        // voice 1's chords must not appear.
        #expect(next == nil || next?.voiceIndex == 0)
    }
}
