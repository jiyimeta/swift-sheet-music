@testable import SheetMusicCore
import Testing

@Suite("SetTie")
struct SetTieTests {
    /// Build a measure with two consecutive C4 quarter chords.
    private static func twoCQuarters() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .half),
        ])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        return Score(division: 480, staves: [staff])
    }

    private static let firstC = NoteID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
    private static let secondC = NoteID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0)

    @Test("apply sets tieForward and tieBack")
    func applyAddsTie() throws {
        var score = Self.twoCQuarters()
        let cmd = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1)
        _ = try cmd.apply(to: &score)
        #expect(score[Self.firstC]?.tieForward == 1)
        #expect(score[Self.secondC]?.tieBack == 1)
    }

    @Test("inverse removes the tie")
    func inverseRemovesTie() throws {
        var score = Self.twoCQuarters()
        let original = score
        let cmd = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("clear-then-set round-trips through inverse")
    func clearThenSetRoundTrips() throws {
        var score = Self.twoCQuarters()
        // Pre-tie the notes manually.
        let pre = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: 1, targetTieBack: 1)
        _ = try pre.apply(to: &score)
        let snapshot = score
        // Now clear via SetTie(...nil).
        let clear = SetTie(
            from: Self.firstC, to: Self.secondC,
            sourceTieForward: nil, targetTieBack: nil)
        let inverse = try clear.apply(to: &score)
        #expect(score[Self.firstC]?.tieForward == nil)
        #expect(score[Self.secondC]?.tieBack == nil)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }
}

@Suite("Score.nextTieTarget")
struct ScoreNextTieTargetTests {
    @Test("returns adjacent same-pitch chord")
    func adjacentSamePitch() {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let score = Score(division: 480,
                          staves: [StaffContent(id: 1,
                              measures: [Measure(voices: [voice])])])
        let source = NoteID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 0,
                            noteIndexInChord: 0)
        let target = score.nextTieTarget(after: source)
        #expect(target?.elementIndex == 1)
        #expect(target?.noteIndexInChord == 0)
    }

    @Test("returns nil when next chord has different pitch")
    func differentPitch() {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 62, tpc: 16)])),
        ])
        let score = Score(division: 480,
                          staves: [StaffContent(id: 1,
                              measures: [Measure(voices: [voice])])])
        let source = NoteID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 0,
                            noteIndexInChord: 0)
        #expect(score.nextTieTarget(after: source) == nil)
    }

    @Test("returns nil when a rest separates the chords")
    func restBetween() {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let score = Score(division: 480,
                          staves: [StaffContent(id: 1,
                              measures: [Measure(voices: [voice])])])
        let source = NoteID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 0,
                            noteIndexInChord: 0)
        #expect(score.nextTieTarget(after: source) == nil)
    }

    @Test("skips non-timed elements (clef / barline)")
    func skipsNonTimedElements() {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .barLine(BarLine()),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let score = Score(division: 480,
                          staves: [StaffContent(id: 1,
                              measures: [Measure(voices: [voice])])])
        let source = NoteID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 0,
                            noteIndexInChord: 0)
        let target = score.nextTieTarget(after: source)
        #expect(target?.elementIndex == 2)
    }
}
