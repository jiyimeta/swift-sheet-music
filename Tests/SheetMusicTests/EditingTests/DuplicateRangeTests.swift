@testable import SheetMusicCore
import Testing

@Suite("DuplicateRange")
struct DuplicateRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0, staff: StaffAddress = flute)
        -> VoiceElementID
    {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int, _ index: Int = 0, part: Int = 0) -> Voice {
        score.parts[part].staves[0].measures[measure].voices[index]
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    /// Two 4/4 bars on one staff whose LAST bar carries a second voice holding a whole-bar rest, over a voice 0
    /// of `C4 D4 r r`. A two-beat selection of voice 0 there copies voice 1's whole-bar rest along with it, and
    /// that rest outlasts the selection by two beats — the shape the append pass has to size itself against.
    private static func wholeBarRestUnderTheLastBar() -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .rest(duration: .quarter), .rest(duration: .quarter),
                .rest(duration: .quarter), .rest(duration: .quarter),
            ])]),
            Measure(voices: [
                Voice(elements: [
                    quarter(60, 14), quarter(62, 16), .rest(duration: .quarter), .rest(duration: .quarter),
                ]),
                Voice(elements: [.rest(duration: .measure)]),
            ]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    @Test("two beats are repeated on the following two beats")
    func repeatsTwoBeats() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ])
    }

    @Test("a whole bar is repeated into the next bar")
    func repeatsWholeBar() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("a voice the source does not have is left alone")
    func leavesOtherVoices() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        // Voice 1's pre-edit value also holds if nothing was written at all, so state that the copy DID land in
        // the same bar's voice 0 — that is what makes voice 1's measure rest "left alone" rather than "unreached".
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Self.voice(score, 1, 1).elements == [.rest(duration: .measure)])
    }

    @Test("every staff's copy lands in its own staff")
    func multiStaff() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 1, staff: Self.cello),
        )).apply(to: &score)
        #expect(Self.voice(score, 0).elements.count == 5)
        #expect(Self.voice(score, 0, part: 1).elements.count >= 2)
        // The two counts above hold even if nothing had been written, so state where each staff's copy landed:
        // the flute's bar into the flute, the cello's measure rest into the cello, neither into the other.
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Self.voice(score, 1, part: 1).elements == [.rest(duration: .measure)])
    }

    @Test("a triplet is repeated as a triplet")
    func repeatsTuplet() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateTuplet(at: Self.slot(0, 1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)))
            .apply(to: &score)
        let spans = Self.voice(score, 0).tupletSpans
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.actualNotes == 3 })
        // A count and a ratio hold even if the copy landed on the wrong slots, so name where the two brackets
        // sit and assert the copied members are the source members, element for element. The source triplet
        // occupies 1...3 (after the time signature); the copy replaces the quarter that stood at tick 480.
        let elements = Self.voice(score, 0).elements
        #expect(spans.map(\.startIndex) == [1, 4])
        #expect(spans.map(\.endIndex) == [3, 6])
        #expect(Array(elements.values[4 ... 6]) == Array(elements.values[1 ... 3]))
    }

    @Test("repeating the last bar appends measures")
    func appendsAtScoreEnd() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 5)
        #expect(score.parts[1].staves[0].measures.count == 5)
    }

    @Test("an element whose onset was in range but that sounds past it is truncated, not copied whole")
    func truncatesMaterialOutlastingTheRange() throws {
        var score = Self.wholeBarRestUnderTheLastBar()
        // Two beats of the last bar's voice 0. Voice 1's whole-bar rest is selected with them — the selection
        // goes by ONSET — but MuseScore parity truncates it to the range's own two beats rather than copying it
        // whole, so nothing needs appending: the old (wrong) behavior copied the whole bar's rest and spilled a
        // half note into a bar that did not exist yet.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 1)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 2)
        #expect(Self.voice(score, 1).elements == [
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(60, 14), Self.quarter(62, 16),
        ])
        // The whole-bar rest is truncated to the two beats (beats 3-4) the range covers — it no longer reaches
        // into a new bar at all. Splitting it there also re-spells its own leading half (beats 1-2, still the
        // original rest's identity, just shortened).
        #expect(Self.voice(score, 1, 1).elements == [.rest(duration: .half), .rest(duration: .half)])
    }

    /// A 4/4 bar (voice 0: three quarter rests then a half note starting on beat 4 that would sound 480 ticks
    /// past the bar; voice 1: four quarter rests) followed by a second bar of four distinct quarters in each
    /// voice, so the material after the copy carries a fingerprint of its own. Mirrors
    /// `RangeCopySourceTests.lastElementClampedToRangeEnd`'s shape.
    private static func overhangingHalfNoteBeforeASentinelBar() -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [
                Voice(elements: [
                    .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
                    .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
                ]),
                Voice(elements: [
                    .rest(duration: .quarter), .rest(duration: .quarter),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ]),
            ]),
            Measure(voices: [
                Voice(elements: [
                    Self.quarter(72, 14), Self.quarter(74, 16), Self.quarter(76, 18), Self.quarter(77, 19),
                ]),
                Voice(elements: [
                    Self.quarter(79, 21), Self.quarter(81, 23), Self.quarter(83, 12), Self.quarter(84, 14),
                ]),
            ]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    @Test("an element that sounds past the range's end is truncated, and only its own two beats are overwritten")
    func truncatesOverhangingElement() throws {
        var score = Self.overhangingHalfNoteBeforeASentinelBar()
        // Voice 1's beats 3-4 anchor the range; `voiceElements(in:)` selects by onset, so voice 0's beat-3 rest
        // and its overhanging beat-4 half note come along too.
        _ = try DuplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 2, voice: 1), end: Self.slot(0, 3, voice: 1),
        )).apply(to: &score)

        // Still two bars: the truncated copy fits inside the two beats it owns, so nothing needed appending —
        // the old (wrong) behavior copied the half note whole and forced a third bar into existence.
        #expect(score.parts[0].staves[0].measures.count == 2)
        #expect(Self.voice(score, 1).elements[0] == .rest(duration: .quarter))
        guard case let .chord(truncated) = Self.voice(score, 1).elements[1] else {
            Issue.record("expected the truncated half note re-spelled as a chord")
            return
        }
        #expect(truncated.duration == .quarter)
        #expect(truncated.notes.map(\.pitch) == [60])
        // Beats 3-4 of the destination bar are untouched — the write did not run past the two beats it owns.
        #expect(Self.voice(score, 1).elements[2] == Self.quarter(76, 18))
        #expect(Self.voice(score, 1).elements[3] == Self.quarter(77, 19))
    }

    @Test("undo restores the score exactly, appended measures included")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score != before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a dotted note is copied as a dotted note, not as a tied pair")
    func keepsDots() throws {
        var score = EditingFixtures.parityFixture()
        let dotted = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 3, denominator: 8)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        score[Self.slot(0, 1)] = dotted
        score[Self.slot(0, 2)] = .rest(duration: .eighth)
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        #expect(Self.voice(score, 0).elements[3] == dotted)
    }

    @Test("a whole-bar rest is copied as a measure rest")
    func keepsMeasureRest() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures[4].voices[0].elements == [.rest(duration: .measure)])
    }

    @Test("an articulation hanging off a copied chord comes along")
    func keepsArticulations() throws {
        var score = EditingFixtures.parityFixture()
        let staccato = ChordArticulation(kind: .staccato)
        score[Self.slot(0, 1)] = .chord(Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)], articulations: [staccato],
        ))
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        guard case let .chord(copied) = Self.voice(score, 0).elements[3] else {
            Issue.record("element 3 should be the copy of the articulated chord")
            return
        }
        // Name the pitch too: an empty articulation list on the WRONG element would also read as "kept".
        #expect(copied.notes[0].pitch == 60)
        #expect(copied.articulations == [staccato])
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)))
                .apply(to: &score)
        }
    }

    /// A dotted half (three quarter beats) turned into a triplet, followed by a plain quarter — "beats 1-3 are a
    /// triplet, beat 4 is a quarter" per the task brief. The triplet's members land at indices 0-2; the quarter
    /// is index 3.
    private static func tripletThenQuarter() throws -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .fraction(Fraction(numerator: 3, denominator: 4)), notes: [Note(pitch: 60, tpc: 14)],
                )),
                Self.quarter(62, 16),
            ])]),
        ])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        _ = try CreateTuplet(at: Self.slot(0, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }

    @Test("a range covering a tuplet only partially is refused, and leaves the score untouched")
    func refusesPartialTuplet() throws {
        var score = try Self.tripletThenQuarter()
        let before = score
        // The triplet's second member (index 1) through the trailing quarter (index 3): the range starts one
        // member into the triplet, so the bracket cannot be stated on the copy.
        #expect(throws: SheetMusicError.self) {
            _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)))
                .apply(to: &score)
        }
        #expect(score == before)
    }

    @Test("a range covering the whole tuplet plus the following beat succeeds")
    func repeatsWholeTupletPlusFollowingBeat() throws {
        var score = try Self.tripletThenQuarter()
        // The range's own bar (four beats) is exactly one measure, so the copy lands in a freshly appended
        // measure 1 rather than sharing measure 0 with the source the way `repeatsTuplet` does.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        #expect(Self.voice(score, 0).tupletSpans.count == 1)
        let copiedSpans = Self.voice(score, 1).tupletSpans
        #expect(copiedSpans.count == 1)
        #expect(copiedSpans.allSatisfy { $0.actualNotes == 3 })
    }
}
