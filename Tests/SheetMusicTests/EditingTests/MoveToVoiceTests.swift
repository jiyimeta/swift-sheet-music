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

    private static let tripletMember = VoiceElement.chord(
        Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)]),
    )

    /// Measure 1 of the flute, rebuilt so the move collapses MORE than one destination rest: voice 0 opens with a
    /// half note, and voice 1 is two quarter rests on beats 1–2 followed by a quarter-note triplet on beats 3–4.
    /// The tuplet's endpoints index elements 2...4 and must survive the collapse of elements 0 and 1 into one.
    private static func tripletDestinationScore() -> Score {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[1].voices[0] = Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        score.parts[0].staves[0].measures[1].voices[1] = Voice(
            elements: [
                .rest(duration: .quarter), .rest(duration: .quarter),
                tripletMember, tripletMember, tripletMember,
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)],
        )
        return score
    }

    @Test("a tuplet later in the destination voice keeps its members")
    func shiftsTupletAfterTheCollapsedRun() throws {
        var score = Self.tripletDestinationScore()

        // The half note covers [0, 960), which is two quarter rests — they collapse into one element.
        _ = try MoveToVoice(at: Self.slot(1, 0), to: Self.voiceOne(1)).apply(to: &score)

        let measure = score.parts[0].staves[0].measures[1]
        #expect(measure.voices[0].elements[0] == .rest(duration: .half))
        let v1 = measure.voices[1]
        #expect(v1.elements == [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
            Self.tripletMember, Self.tripletMember, Self.tripletMember,
        ])
        #expect(v1.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)])
    }

    @Test("undo restores the destination voice's tuplet endpoints")
    func undoRestoresTupletEndpoints() throws {
        var score = Self.tripletDestinationScore()
        let before = score

        let inverse = try MoveToVoice(at: Self.slot(1, 0), to: Self.voiceOne(1)).apply(to: &score)
        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("a destination voice that stops before the span is refused, not silently emptied")
    func refusesDestinationShorterThanTheSpan() throws {
        var score = EditingFixtures.parityFixture()
        // A legal partial voice: voice 1 of bar 1 holds one quarter rest on beat 1 and stops there.
        score.parts[0].staves[0].measures[1].voices[1] = Voice(elements: [.rest(duration: .quarter)])
        score[Self.slot(1, 2)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)]))
        let before = score

        let short = #expect(throws: SheetMusicError.self) {
            _ = try MoveToVoice(at: Self.slot(1, 2), to: Self.voiceOne(1)).apply(to: &score)
        }

        let destinationStart = VoiceElementID(staff: Self.flute, measureIndex: 1, voiceIndex: 1, elementIndex: 0)
        #expect(Self.reason(of: short) == .destinationNotFree(destinationStart))
        #expect(score == before, "a refused move leaves the score untouched — the chord is not dropped")
    }

    @Test("a tuplet before the moved chord is refused rather than moved to a mistimed slot")
    func refusesTupletBeforeTheSlot() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0] = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                Self.tripletMember, Self.tripletMember, Self.tripletMember,
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
        )
        let before = score

        let mistimed = #expect(throws: SheetMusicError.self) {
            _ = try MoveToVoice(at: Self.slot(0, 4), to: Self.voiceOne(0)).apply(to: &score)
        }

        #expect(Self.reason(of: mistimed) == .tupletPrecedesSlot(at: Self.slot(0, 4)))
        #expect(score == before)
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
