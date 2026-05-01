import SheetMusicCore
import Testing

@Suite("Score.items(inRangeFrom:to:)")
struct NoteRangeTests {
    private func makeSingleStaffScore() -> Score {
        // One staff, two measures, each with one voice, four quarter notes.
        func chord(_ pitch: Int) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: pitch, tpc: 14)]))
        }
        let m1 = Measure(voices: [
            Voice(elements: [chord(60), chord(62), chord(64), chord(65)])
        ])
        let m2 = Measure(voices: [
            Voice(elements: [chord(67), chord(69), chord(71), chord(72)])
        ])
        return Score(
            division: 480,
            staves: [StaffContent(id: 1, measures: [m1, m2])])
    }

    private func makeSingleStaffScoreWithRests() -> Score {
        // chord(60), rest(quarter), chord(64), rest(quarter)
        let m1 = Measure(voices: [
            Voice(elements: [
                .chord(Chord(duration: .quarter,
                             notes: [Note(pitch: 60, tpc: 14)])),
                .rest(Rest(duration: .quarter)),
                .chord(Chord(duration: .quarter,
                             notes: [Note(pitch: 64, tpc: 14)])),
                .rest(Rest(duration: .quarter))
            ])
        ])
        return Score(
            division: 480,
            staves: [StaffContent(id: 1, measures: [m1])])
    }

    private func makeTwoStaffScore() -> Score {
        func chord(_ pitch: Int) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: pitch, tpc: 14)]))
        }
        let m1a = Measure(voices: [
            Voice(elements: [chord(72), chord(74), chord(76), chord(77)])
        ])
        let m1b = Measure(voices: [
            Voice(elements: [chord(48), chord(50), chord(52), chord(53)])
        ])
        return Score(
            division: 480,
            staves: [
                StaffContent(id: 1, measures: [m1a]),
                StaffContent(id: 2, measures: [m1b])
            ])
    }

    private func note(
        _ staff: Int, _ measure: Int, _ voice: Int,
        _ element: Int, _ noteInChord: Int = 0
    ) -> ScoreItemID {
        .note(NoteID(
            staffIndex: staff, measureIndex: measure,
            voiceIndex: voice, elementIndex: element,
            noteIndexInChord: noteInChord))
    }

    private func rest(
        _ staff: Int, _ measure: Int, _ voice: Int, _ element: Int
    ) -> ScoreItemID {
        .rest(RestID(
            staffIndex: staff, measureIndex: measure,
            voiceIndex: voice, elementIndex: element))
    }

    @Test("Anchor == target returns exactly one item")
    func degenerateRange() {
        let score = makeSingleStaffScore()
        let id = note(0, 0, 0, 2)
        #expect(score.items(inRangeFrom: id, to: id) == [id])
    }

    @Test("Range within a single measure covers items between endpoints")
    func withinMeasure() {
        let score = makeSingleStaffScore()
        let anchor = note(0, 0, 0, 1)
        let target = note(0, 0, 0, 3)
        let result = score.items(inRangeFrom: anchor, to: target)
        #expect(result.count == 3)
        #expect(result.map(\.elementIndex) == [1, 2, 3])
    }

    @Test("Range spanning two measures covers the gap")
    func spansMeasures() {
        let score = makeSingleStaffScore()
        let anchor = note(0, 0, 0, 2)
        let target = note(0, 1, 0, 1)
        let result = score.items(inRangeFrom: anchor, to: target)
        // m0 elements 2,3 + m1 elements 0,1 = 4 notes
        #expect(result.count == 4)
    }

    @Test("Reversed order (target before anchor) normalizes")
    func reversedOrder() {
        let score = makeSingleStaffScore()
        let a = note(0, 1, 0, 3)
        let b = note(0, 0, 0, 0)
        let forward = score.items(inRangeFrom: b, to: a)
        let reverse = score.items(inRangeFrom: a, to: b)
        #expect(forward == reverse)
        #expect(forward.count == 8)
    }

    @Test("Range spanning staves covers both")
    func spansStaves() {
        let score = makeTwoStaffScore()
        let anchor = note(0, 0, 0, 1)
        let target = note(1, 0, 0, 2)
        let result = score.items(inRangeFrom: anchor, to: target)
        // Each staff has elements 1 and 2 in the tick range → 2 × 2 = 4.
        #expect(result.count == 4)
        #expect(Set(result.map(\.staffIndex)) == [0, 1])
    }

    @Test("Invalid ID returns empty array")
    func invalidIDs() {
        let score = makeSingleStaffScore()
        let bogus = note(99, 0, 0, 0)
        let ok = note(0, 0, 0, 0)
        #expect(score.items(inRangeFrom: bogus, to: ok).isEmpty)
        #expect(score.items(inRangeFrom: ok, to: bogus).isEmpty)
    }

    @Test("Range covering chords and rests returns both kinds")
    func mixedChordAndRest() {
        let score = makeSingleStaffScoreWithRests()
        // From the first chord (element 0) through the second rest
        // (element 3): should return 2 notes + 2 rests = 4 items.
        let anchor = note(0, 0, 0, 0)
        let target = rest(0, 0, 0, 3)
        let result = score.items(inRangeFrom: anchor, to: target)
        #expect(result.count == 4)
        let noteCount = result.filter {
            if case .note = $0 { return true } else { return false }
        }.count
        let restCount = result.filter {
            if case .rest = $0 { return true } else { return false }
        }.count
        #expect(noteCount == 2)
        #expect(restCount == 2)
    }

    @Test("Long note in another staff extends range across short notes")
    func longerEndpointExtendsCoverage() {
        // staff 0: 8 eighths. staff 1: 1 whole — both starting at
        // tick 0 of measure 0. Selecting the first eighth (staff 0)
        // and shift-clicking the whole (staff 1) should cover EVERY
        // eighth in staff 0, not just the two clicked endpoints,
        // because the whole's duration extends the range to the
        // end of the bar.
        func eighth(_ pitch: Int) -> VoiceElement {
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: pitch, tpc: 14)]))
        }
        let s0m0 = Measure(voices: [
            Voice(elements: [
                eighth(60), eighth(62), eighth(64), eighth(65),
                eighth(67), eighth(69), eighth(71), eighth(72)])
        ])
        let s1m0 = Measure(voices: [
            Voice(elements: [
                .chord(Chord(
                    duration: .whole,
                    notes: [Note(pitch: 48, tpc: 14)]))])
        ])
        let score = Score(
            division: 480,
            staves: [
                StaffContent(id: 1, measures: [s0m0]),
                StaffContent(id: 2, measures: [s1m0])])
        let firstEighth = note(0, 0, 0, 0)
        let whole = note(1, 0, 0, 0)
        let result = score.items(
            inRangeFrom: firstEighth, to: whole)
        // 8 notes from staff 0 + 1 note from staff 1 = 9 IDs.
        #expect(result.count == 9)
        #expect(Set(result.map(\.staffIndex)) == [0, 1])
    }

    @Test("Clicking a rest anchors the range")
    func restAsAnchor() {
        let score = makeSingleStaffScoreWithRests()
        // Range from the first rest (element 1) to the last chord
        // (element 2).
        let anchor = rest(0, 0, 0, 1)
        let target = note(0, 0, 0, 2)
        let result = score.items(inRangeFrom: anchor, to: target)
        // Elements 1 (rest) and 2 (chord's one note) → 2 items.
        #expect(result.count == 2)
    }
}
