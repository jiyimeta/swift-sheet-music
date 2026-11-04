@testable import SheetMusicCore
import Testing

/// A breath written at the head of a bar, ahead of the bar's first chord — where a file can carry one that follows
/// the previous bar's last chord (MuseScore's element paste re-homes a `<Breath>` by tick and leaves it there). It
/// belongs to that chord, so `SetBreath(after:)` on the chord has to reach it: to replace it and to remove it.
@Suite("SetBreath — a breath at the head of the next bar")
struct SetBreathBarHeadTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let comma = Breath(kind: .breathMark(.comma), pause: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func score(_ bars: [VoiceElement]...) -> Score {
        let staff = Staff(defaultClefType: "G", measures: bars.map { Measure(voices: [Voice(elements: $0)]) })
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff])])
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements.values
    }

    /// Bar 0 ends on E4; bar 1 opens with a breath, then F4.
    private static func barHeadScore(_ head: [VoiceElement] = [.breath(comma)]) -> Score {
        score(
            [chord(60, .quarter), chord(62, .quarter), chord(64, .half)],
            head + [chord(65, .whole)],
        )
    }

    @Test("the chord ending a bar owns the breath at the head of the next")
    func current() {
        let score = Self.barHeadScore()
        #expect(SetBreath.current(after: Self.slot(0, 2), in: score) == Self.comma)
    }

    @Test("nil removes it from the next bar, leaving the chord's bar alone; the inverse restores it")
    func removes() throws {
        var score = Self.barHeadScore()
        let before = score
        let inverse = try SetBreath(after: Self.slot(0, 2), kind: nil, pause: 0).apply(to: &score)
        #expect(Self.elements(score, 1) == [Self.chord(65, .whole)])
        #expect(Self.elements(score, 0) == Self.elements(before, 0))
        #expect(SetBreath.current(after: Self.slot(0, 2), in: score) == nil)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a kind replaces it where it stands, keeping its visibility, rather than adding a second breath")
    func replacesInPlace() throws {
        var hidden = Self.comma
        hidden.visible = false
        var score = Self.barHeadScore([.breath(hidden)])
        _ = try SetBreath(after: Self.slot(0, 2), kind: .caesura(.normal), pause: 0.5).apply(to: &score)
        #expect(Self.elements(score, 0).count == 3)
        guard case let .breath(breath) = Self.elements(score, 1)[0] else {
            Issue.record("expected the bar-head breath to stay at the head of bar 1")
            return
        }
        #expect(breath.kind == .caesura(.normal))
        #expect(breath.pause == 0.5)
        #expect(breath.visible == false)
        #expect(Self.elements(score, 1).count == 2)
    }

    @Test("signatures opening the bar ahead of the breath do not hide it")
    func behindLeadingSignatures() throws {
        var score = Self.barHeadScore([.keySignature(KeySignature(concertKey: 2)), .breath(Self.comma)])
        #expect(SetBreath.current(after: Self.slot(0, 2), in: score) == Self.comma)
        _ = try SetBreath(after: Self.slot(0, 2), kind: nil, pause: 0).apply(to: &score)
        #expect(Self.elements(score, 1) == [.keySignature(KeySignature(concertKey: 2)), Self.chord(65, .whole)])
    }

    @Test("the chord's own breath in its bar comes first; the next bar's head is reached after it is gone")
    func ownRunFirst() throws {
        let tick = Breath(kind: .breathMark(.tick), pause: 0)
        var score = Self.score(
            [Self.chord(60, .whole), .breath(tick)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        #expect(SetBreath.current(after: Self.slot(0, 0), in: score) == tick)
        _ = try SetBreath(after: Self.slot(0, 0), kind: nil, pause: 0).apply(to: &score)
        #expect(Self.elements(score, 0) == [Self.chord(60, .whole)])
        #expect(SetBreath.current(after: Self.slot(0, 0), in: score) == Self.comma)
        _ = try SetBreath(after: Self.slot(0, 0), kind: nil, pause: 0).apply(to: &score)
        #expect(Self.elements(score, 1) == [Self.chord(65, .whole)])
    }

    @Test("only the bar's last timed element reaches over the barline")
    func onlyTheLastChord() {
        var score = Self.barHeadScore()
        let before = score
        #expect(SetBreath.current(after: Self.slot(0, 1), in: score) == nil)
        #expect(throws: SheetMusicError.self) {
            _ = try SetBreath(after: Self.slot(0, 1), kind: nil, pause: 0).apply(to: &score)
        }
        #expect(score == before)
    }

    @Test("a bar ending on a rest: the rest owns it, and the chord before the rest does not reach past it")
    func restEndedBar() throws {
        var score = Self.score(
            [Self.chord(60, .half), .rest(duration: .half)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        #expect(SetBreath.current(after: Self.slot(0, 0), in: score) == nil)
        #expect(SetBreath.current(after: Self.slot(0, 1), in: score) == Self.comma)
        _ = try SetBreath(after: Self.slot(0, 1), kind: nil, pause: 0).apply(to: &score)
        #expect(Self.elements(score, 1) == [Self.chord(65, .whole)])
    }

    @Test("a breath in the middle of the next bar is not at its head")
    func notAtTheHead() {
        let score = Self.score(
            [Self.chord(60, .whole)],
            [Self.chord(65, .half), .breath(Self.comma), Self.chord(67, .half)],
        )
        #expect(SetBreath.current(after: Self.slot(0, 0), in: score) == nil)
    }

    @Test("with no breath anywhere, a new one is still written in the chord's own bar")
    func insertsInOwnBar() throws {
        var score = Self.score([Self.chord(60, .whole)], [Self.chord(65, .whole)])
        _ = try SetBreath(after: Self.slot(0, 0), kind: .breathMark(.comma), pause: 0).apply(to: &score)
        #expect(Self.elements(score, 0) == [Self.chord(60, .whole), .breath(Self.comma)])
        #expect(Self.elements(score, 1) == [Self.chord(65, .whole)])
    }
}
