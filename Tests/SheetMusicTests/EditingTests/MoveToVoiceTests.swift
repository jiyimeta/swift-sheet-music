@testable import SheetMusicCore
import Testing

@Suite("MoveToVoice")
struct MoveToVoiceTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func voiceOne(_ measure: Int) -> VoiceRef {
        VoiceRef(staff: flute, measureIndex: measure, voiceIndex: 1)
    }

    @Test("moves a quarter chord into a fresh voice at the same beat")
    func movesIntoNewVoice() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r, r]
        _ = try MoveToVoice(at: Self.slot(0, 2), to: Self.voiceOne(0)).apply(to: &score)
        let voices = score.parts[0].staves[0].measures[0].voices
        #expect(voices.count == 2)
        #expect(voices[0].elements[2] == .rest(duration: .quarter))
        // Voice 1 was a measure rest. `SplitRest` spells the cut at tick 480 as `[q] + [q, h]`, so after the
        // chord replaces the run covering [480, 960) the voice reads `r q, D4 q, r h` — pinned exactly.
        let v1 = voices[1].elements
        #expect(v1 == [
            .rest(duration: .quarter),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .half),
        ])
        let measureDuration = Fraction(numerator: 4, denominator: 4)
        let ticks = v1.reduce(0) { sum, element in
            guard case let .chord(chord) = element else { return sum }
            return sum + chord.duration.resolved(in: measureDuration).ticks(division: 480)
        }
        #expect(ticks == 1920)
    }

    @Test("undo restores the score exactly, including dropping the created voice")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try MoveToVoice(at: Self.slot(0, 1), to: Self.voiceOne(0)).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("moves into an existing voice whose rest already covers the span")
    func movesIntoExistingVoice() throws {
        var score = EditingFixtures.parityFixture()
        score[Self.slot(1, 1)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)]))
        _ = try MoveToVoice(at: Self.slot(1, 1), to: Self.voiceOne(1)).apply(to: &score)
        let v1 = score.parts[0].staves[0].measures[1].voices[1].elements
        guard case let .chord(moved) = v1[1] else {
            Issue.record("expected the chord at beat 2")
            return
        }
        #expect(moved.notes[0].pitch == 65)
    }

    @Test("a destination whose span holds a note, another measure, or the same voice is refused")
    func refusals() throws {
        var score = EditingFixtures.parityFixture()
        _ = try MoveToVoice(at: Self.slot(0, 1), to: Self.voiceOne(0)).apply(to: &score)
        var again = score
        // Beat 1 of voice 1 now holds the moved C4, so the rest left behind at beat 1 has nowhere to go.
        let occupied = #expect(throws: SheetMusicError.self) {
            _ = try MoveToVoice(at: Self.slot(0, 1), to: Self.voiceOne(0)).apply(to: &again)
        }
        let blocker = VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 1, elementIndex: 0)
        #expect(Self.reason(of: occupied) == .destinationNotFree(blocker))
        let otherMeasure = #expect(throws: SheetMusicError.self) {
            _ = try MoveToVoice(at: Self.slot(0, 2), to: Self.voiceOne(1)).apply(to: &again)
        }
        #expect(Self.reason(of: otherMeasure) == .voiceMismatch(
            from: VoiceRef(Self.slot(0, 2)), to: Self.voiceOne(1),
        ))
        let sameVoice = #expect(throws: SheetMusicError.self) {
            let destination = VoiceRef(staff: Self.flute, measureIndex: 0, voiceIndex: 0)
            _ = try MoveToVoice(at: Self.slot(0, 2), to: destination).apply(to: &again)
        }
        #expect(Self.reason(of: sameVoice) == .voiceMismatch(
            from: VoiceRef(Self.slot(0, 2)), to: VoiceRef(staff: Self.flute, measureIndex: 0, voiceIndex: 0),
        ))
        #expect(again == score, "a refused move leaves the score untouched")
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
