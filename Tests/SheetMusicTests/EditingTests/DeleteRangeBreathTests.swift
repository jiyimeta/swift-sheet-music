@testable import SheetMusicCore
import Testing

/// A breath belongs to the chord or rest before it (`SetBreath`), so a range delete takes every breath whose owner the
/// range covers — the one after the range's last slot included, and the one at the head of the next bar when the
/// range covers the slot ending the bar before. A breath whose owner lies outside the range stays. A range of nothing
/// but rests still takes its breaths. (Owner, 2026-11-01: before this, a deleted bar kept its breath behind the
/// measure rest, where nothing could select it.)
@Suite("DeleteRange — breaths")
struct DeleteRangeBreathTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let comma = VoiceElement.breath(Breath(kind: .breathMark(.comma), pause: 0))

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func range(_ start: VoiceElementID, _ end: VoiceElementID) -> VoiceElementRange {
        VoiceElementRange(start: start, end: end)
    }

    private static func chord(_ pitch: Int, _ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func score(_ bars: [[VoiceElement]]...) -> Score {
        let staff = Staff(defaultClefType: "G", measures: bars.map { voices in
            Measure(voices: voices.map { Voice(elements: $0) })
        })
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff])])
    }

    private static func elements(_ score: Score, _ measure: Int, voice: Int = 0) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[voice].elements.values
    }

    @Test("a whole bar with a breath in the middle comes back as one measure rest, and undo restores it")
    func wholeBar() throws {
        var score = Self.score([[
            Self.chord(66, .half.dotted(1)), Self.chord(66, .eighth), Self.comma, Self.chord(67, .eighth),
        ]])
        let before = score
        let inverse = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 3))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the breath after the range's last slot goes with it, and the rests on either side of it join up")
    func afterTheLastSlot() throws {
        var score = Self.score([[
            Self.chord(60, .quarter), Self.chord(62, .quarter), Self.comma, Self.chord(64, .quarter),
            Self.chord(65, .quarter),
        ]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 1))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .half), Self.chord(64, .quarter), Self.chord(65, .quarter)])
    }

    @Test("a breath inside the range splits nothing: the covered slots on both sides fill as one run")
    func insideTheRange() throws {
        var score = Self.score([[
            Self.chord(60, .quarter), Self.comma, Self.chord(62, .quarter), Self.chord(64, .half),
        ]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 2))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .half), Self.chord(64, .half)])
    }

    @Test("a breath following a slot before the range stays")
    func ownerBeforeTheRange() throws {
        var score = Self.score([[
            Self.chord(60, .quarter), Self.comma, Self.chord(62, .quarter), Self.chord(64, .half),
        ]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 2), Self.slot(0, 2))).apply(to: &score)
        #expect(Array(Self.elements(score, 0).prefix(2)) == [Self.chord(60, .quarter), Self.comma])
        #expect(!Self.elements(score, 0).dropFirst(2).contains(Self.comma))
    }

    @Test("a range of rests alone still takes the breath after them")
    func restsOnly() throws {
        var score = Self.score([[.rest(duration: .measure), Self.comma]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 0))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
    }

    @Test("the breath at the head of the next bar goes when the range covers the slot ending the bar before")
    func nextBarsHeadOutsideTheRange() throws {
        var score = Self.score([[Self.chord(60, .whole)]], [[Self.comma, Self.chord(65, .whole)]])
        let before = score
        let inverse = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 0))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
        #expect(Self.elements(score, 1) == [Self.chord(65, .whole)])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the breath at the head of a bar inside the range goes with the bar before's last slot")
    func nextBarsHeadInsideTheRange() throws {
        var score = Self.score([[Self.chord(60, .whole)]], [[Self.comma, Self.chord(65, .whole)]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(1, 1))).apply(to: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
        #expect(Self.elements(score, 1) == [.rest(duration: .measure)])
    }

    @Test("the breath at the head of the range's first bar follows the bar before, outside the range, and stays")
    func firstBarsHeadStays() throws {
        var score = Self.score([[Self.chord(60, .whole)]], [[Self.comma, Self.chord(65, .whole)]])
        _ = try DeleteRange(over: Self.range(Self.slot(1, 1), Self.slot(1, 1))).apply(to: &score)
        #expect(Self.elements(score, 0) == [Self.chord(60, .whole)])
        #expect(Self.elements(score, 1) == [Self.comma, .rest(duration: .measure)])
    }

    @Test("an emptied bar drops an upper voice whose only other element was a breath the range took")
    func upperVoiceGoes() throws {
        var score = Self.score([[Self.chord(60, .whole)], [Self.chord(67, .whole), Self.comma]])
        _ = try DeleteRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 0))).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[0].voices.count == 1)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
    }
}
