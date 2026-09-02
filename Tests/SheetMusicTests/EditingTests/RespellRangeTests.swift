@testable import SheetMusicCore
import Testing

@Suite("RespellRange")
struct RespellRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ score: Score, _ measure: Int, _ element: Int) -> Note? {
        guard case let .chord(chord)? = score[slot(measure, element)] else { return nil }
        return chord.notes.first
    }

    /// The parity fixture with D♯4 (63, tpc 23, ♯) at m0 element 1 and a G♭4 (66, tpc 8, ♭) tie chain in m2.
    private static func spelledScore() -> Score {
        var score = EditingFixtures.parityFixture()
        score[slot(0, 1)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 63, tpc: 23, accidental: .sharp)]))
        var head = Note(pitch: 66, tpc: 8, accidental: .flat)
        head.tieForward = 1
        var tail = Note(pitch: 66, tpc: 8)
        tail.tieBack = 1
        score[slot(2, 0)] = .chord(Chord(duration: .half, notes: [head]))
        score[slot(2, 1)] = .chord(Chord(duration: .half, notes: [tail]))
        return score
    }

    @Test("prefer flats respells D♯ as E♭ at the same pitch")
    func preferFlats() throws {
        var score = Self.spelledScore()
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1))
        _ = try RespellRange(over: range, mode: .preferFlats).apply(to: &score)
        #expect(Self.note(score, 0, 1)?.pitch == 63)
        #expect(Self.note(score, 0, 1)?.tpc == 11)
        #expect(Self.note(score, 0, 1)?.accidental == .flat)
    }

    @Test("simplest in C major agrees with prefer flats on D♯ and with prefer sharps on G♭")
    func simplest() throws {
        var score = Self.spelledScore()
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(2, 1))
        _ = try RespellRange(over: range, mode: .simplest).apply(to: &score)
        #expect(Self.note(score, 0, 1)?.tpc == 11) // E♭
        #expect(Self.note(score, 2, 0)?.tpc == 20) // F♯
        #expect(Self.note(score, 2, 0)?.accidental == .sharp)
    }

    @Test("a tie chain is respelled whole when only its tail is in range, glyph on the head only")
    func tieChain() throws {
        var score = Self.spelledScore()
        let range = VoiceElementRange(start: Self.slot(2, 1), end: Self.slot(2, 1))
        _ = try RespellRange(over: range, mode: .preferSharps).apply(to: &score)
        #expect(Self.note(score, 2, 0)?.tpc == 20)
        #expect(Self.note(score, 2, 0)?.accidental == .sharp)
        #expect(Self.note(score, 2, 1)?.tpc == 20)
        #expect(Self.note(score, 2, 1)?.accidental == nil)
        #expect(Self.note(score, 2, 1)?.pitch == 66)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = Self.spelledScore()
        let before = score
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(2, 1))
        let inverse = try RespellRange(over: range, mode: .preferFlats).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a note already spelled that way, and rests, contribute nothing")
    func restatingIsInert() throws {
        var score = Self.spelledScore()
        let before = score
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(1, 3))
        _ = try RespellRange(over: range, mode: .preferSharps).apply(to: &score)
        #expect(score == before)
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = Self.spelledScore()
        #expect(throws: SheetMusicError.self) {
            _ = try RespellRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(8, 0)), mode: .simplest)
                .apply(to: &score)
        }
    }
}
