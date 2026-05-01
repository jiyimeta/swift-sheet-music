@testable import SheetMusicCore
import Testing

@Suite("SetChordDuration")
struct SetChordDurationTests {
    private func chord(_ d: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: d, notes: [Note(pitch: 60, tpc: 14)]))
    }
    private func rest(_ d: NoteDuration) -> VoiceElement {
        .rest(Rest(duration: d))
    }
    /// Build a single-measure 4/4 score whose voice 0 is `elements`.
    private func score(_ elements: [VoiceElement]) -> Score {
        let voice = Voice(elements: elements)
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        return Score(division: 480, staves: [staff])
    }
    private func first(_ score: Score) -> [VoiceElement] {
        score.staves[0].measures[0].voices[0].elements
    }
    private static let chordID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 0)

    @Test("Shorten quarter → eighth fills the leftover with an eighth rest")
    func shortenQuarterToEighth() throws {
        var score = score([chord(.quarter), rest(.half),
                                rest(.eighth), rest(.eighth)])
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .eighth)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // Expect: chord(.eighth), rest(.eighth), rest(.half),
        //         rest(.eighth), rest(.eighth)
        guard case .chord(let c) = els[0] else {
            Issue.record("element 0 not chord"); return
        }
        #expect(c.duration == .eighth)
        guard case .rest(let r) = els[1] else {
            Issue.record("element 1 not rest"); return
        }
        #expect(r.duration == .eighth)
        // total tick count unchanged
        let totalTicks = els.reduce(0) { acc, el in
            switch el {
            case .chord(let c):
                return acc + c.duration.ticks(division: 480)
            case .rest(let r):
                return acc + r.duration.ticks(division: 480)
            default:
                return acc
            }
        }
        #expect(totalTicks == 4 * 480)
    }

    @Test("Lengthen eighth → quarter consumes the next rest exactly")
    func lengthenExactConsume() throws {
        var score = score([
            chord(.eighth), rest(.eighth), rest(.half), rest(.quarter)])
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // After: chord(.quarter), rest(.half), rest(.quarter)
        #expect(els.count == 3)
        guard case .chord(let c) = els[0] else {
            Issue.record("not chord"); return
        }
        #expect(c.duration == .quarter)
        guard case .rest(let r1) = els[1] else {
            Issue.record("not rest"); return
        }
        #expect(r1.duration == .half)
    }

    @Test("Lengthen with partial consume splits last element into rest")
    func lengthenPartialConsume() throws {
        var score = score([
            chord(.eighth), rest(.half), rest(.quarter),
            rest(.eighth)])
        // From eighth → quarter: needs +1 eighth = 240 ticks.
        // The next element is a half rest (960 ticks): consume 240,
        // leaving 720 ticks (= dotted quarter, decomposed as
        // quarter + eighth).
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // Expected: chord(.quarter), rest(.quarter), rest(.eighth),
        //           rest(.quarter), rest(.eighth)
        guard case .chord(let c) = els[0] else {
            Issue.record("not chord"); return
        }
        #expect(c.duration == .quarter)
        // Verify total ticks unchanged.
        let totalTicks = els.reduce(0) { acc, el in
            switch el {
            case .chord(let c):
                return acc + c.duration.ticks(division: 480)
            case .rest(let r):
                return acc + r.duration.ticks(division: 480)
            default:
                return acc
            }
        }
        #expect(totalTicks == 4 * 480)
    }

    @Test("Inverse round-trips for shorten")
    func shortenRoundTrip() throws {
        var score = score([chord(.quarter), rest(.half),
                                rest(.quarter)])
        let snapshot = score
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .eighth)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("Inverse round-trips for lengthen with partial consume")
    func lengthenRoundTrip() throws {
        var score = score([
            chord(.eighth), rest(.half), rest(.quarter),
            rest(.eighth)])
        let snapshot = score
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("Refuses lengthening past measure end")
    func refusesPastMeasureEnd() {
        var score = score([
            chord(.quarter), rest(.quarter), rest(.eighth)])
        // Available room = 1/4 + 1/8 = 3/8 < lengthening from
        // quarter to whole (needs +3/4).
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .whole)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("Refuses when chord is inside a tuplet")
    func refusesInsideTuplet() {
        let voice = Voice(
            elements: [chord(.eighth), chord(.eighth), chord(.eighth)],
            tuplets: [Tuplet(
                normalNotes: 2, actualNotes: 3,
                startIndex: 0, endIndex: 2)])
        let measure = Measure(voices: [voice])
        var score = Score(
            division: 480,
            staves: [StaffContent(id: 1, measures: [measure])])
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    /// Mirrors MuseScore's `toRhythmicDurationList` rule: the rest
    /// pieces that fill a shortened chord's leftover align to natural
    /// beat boundaries. Whole → eighth at beat 1 produces
    /// `eighth + quarter + half` (smallest first, climbing to bigger
    /// durations at the strong beats), NOT a greedy
    /// `half + quarter + eighth` decomposition.
    @Test("Shorten whole → eighth is rhythm-aligned (MuseScore parity)")
    func shortenWholeToEighthAligned() throws {
        var score = score([chord(.whole)])
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .eighth)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // chord(.eighth), rest(.eighth), rest(.quarter), rest(.half)
        #expect(els.count == 4)
        guard case .chord(let c) = els[0] else {
            Issue.record("not chord"); return
        }
        #expect(c.duration == .eighth)
        guard case .rest(let r1) = els[1] else {
            Issue.record("els[1] not rest"); return
        }
        guard case .rest(let r2) = els[2] else {
            Issue.record("els[2] not rest"); return
        }
        guard case .rest(let r3) = els[3] else {
            Issue.record("els[3] not rest"); return
        }
        #expect(r1.duration == .eighth)
        #expect(r2.duration == .quarter)
        #expect(r3.duration == .half)
    }

    /// Same alignment rule for the lengthen path. Here we lengthen
    /// an 8th chord at beat 1 into a quarter (consuming +1/8 of the
    /// following half rest), which leaves a 720-tick leftover at
    /// rtick 480 — that aligns as quarter + eighth, not the greedy
    /// dotted-quarter equivalent.
    @Test("Lengthen partial leftover aligns to beats")
    func lengthenLeftoverAligned() throws {
        var score = score([
            chord(.eighth),
            rest(.half), rest(.quarter), rest(.eighth)])
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // chord(.quarter), rest(.quarter), rest(.eighth),
        // rest(.quarter), rest(.eighth)
        #expect(els.count == 5)
        guard case .rest(let r1) = els[1] else {
            Issue.record("els[1] not rest"); return
        }
        guard case .rest(let r2) = els[2] else {
            Issue.record("els[2] not rest"); return
        }
        #expect(r1.duration == .quarter)
        #expect(r2.duration == .eighth)
    }

    /// MuseScore parity: lengthening a chord that partially eats
    /// into a following CHORD turns the eaten chord's leftover into
    /// a tied chain of clones (preserving its pitch), with the chain
    /// decomposed by the rhythm-aligned rule.
    @Test("Lengthen partial-consume of next chord → tied clones")
    func lengthenIntoNextChord() throws {
        // chord A (eighth, pitch 60) + chord B (half, pitch 64) +
        // rest (quarter) + rest (eighth)
        let A: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]))
        let B: VoiceElement = .chord(Chord(
            duration: .half, notes: [Note(pitch: 64, tpc: 18)]))
        var score = score([A, B, rest(.quarter), rest(.eighth)])
        // Lengthen A to quarter → consume +240 ticks of B.
        // B's overshoot = 720 ticks at rtick 480, decomposes as
        // quarter (480) + eighth (240).
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // Expected: chord(A=quarter,p60), chord(B'=quarter,p64,tieFwd),
        //           chord(B''=eighth,p64,tieBack), rest(.quarter),
        //           rest(.eighth).
        #expect(els.count == 5)
        guard case .chord(let aa) = els[0] else {
            Issue.record("els[0] not chord"); return
        }
        #expect(aa.duration == .quarter)
        #expect(aa.notes.first?.pitch == 60)
        guard case .chord(let b1) = els[1] else {
            Issue.record("els[1] not chord"); return
        }
        #expect(b1.duration == .quarter)
        #expect(b1.notes.first?.pitch == 64)
        #expect(b1.notes.first?.tieForward == 1)
        #expect(b1.notes.first?.tieBack == nil)
        guard case .chord(let b2) = els[2] else {
            Issue.record("els[2] not chord"); return
        }
        #expect(b2.duration == .eighth)
        #expect(b2.notes.first?.pitch == 64)
        #expect(b2.notes.first?.tieBack == 1)
        // Total ticks unchanged
        let totalTicks = els.reduce(0) { acc, el in
            switch el {
            case .chord(let c):
                return acc + c.duration.ticks(division: 480)
            case .rest(let r):
                return acc + r.duration.ticks(division: 480)
            default: return acc
            }
        }
        #expect(totalTicks == 4 * 480)
    }

    /// Inverse of the above must restore the original B chord
    /// (single half note) after undo.
    @Test("Lengthen-into-chord round-trips through inverse")
    func lengthenIntoChordRoundTrip() throws {
        let A: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]))
        let B: VoiceElement = .chord(Chord(
            duration: .half, notes: [Note(pitch: 64, tpc: 18)]))
        var score = score([A, B, rest(.quarter), rest(.eighth)])
        let snapshot = score
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    /// Lengthening into a tuplet — MuseScore deletes the whole
    /// tuplet as a unit (`makeGap` → `cmdDeleteTuplet`) and the
    /// overshoot becomes plain rests via `setRest`. We mirror that
    /// behaviour: the tuplet vanishes, its tick count is consumed,
    /// and any leftover is rest-decomposed (no tied chord clones).
    @Test("Lengthen consumes a downstream tuplet wholesale")
    func lengthenConsumesTupletWhole() throws {
        // chord A (eighth, p60) at rtick 0
        // tuplet of three eighth chords (3:2 of eighth = 1 quarter of
        // total time) at rticks 240..720 (tuplet members)
        // rest (half) at rtick 720
        let A: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]))
        let t1: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 64, tpc: 18)]))
        let t2: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 65, tpc: 13)]))
        let t3: VoiceElement = .chord(Chord(
            duration: .eighth, notes: [Note(pitch: 67, tpc: 15)]))
        let voice = Voice(
            elements: [A, t1, t2, t3, rest(.half), rest(.eighth)],
            tuplets: [Tuplet(
                normalNotes: 2, actualNotes: 3,
                startIndex: 1, endIndex: 3)])
        let measure = Measure(voices: [voice])
        var score = Score(division: 480,
                          staves: [StaffContent(id: 1,
                              measures: [measure])])
        // Lengthen A from eighth (240) to half (960). Need +720.
        // The tuplet's three eighths within a 3:2 ratio of base
        // eighths actually occupy 480 ticks of measure time
        // (3 * 240 = 720 raw; but tuplet ratio is 2/3 — wait, we
        // model durations AS ALREADY scaled, so each member's
        // .eighth = 240 ticks. The tuplet appears to total 720
        // ticks at face value here, even though musically it
        // would be 480 in the real engraving. For this unit test
        // the raw model-tick view is what matters.)
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .half)
        _ = try cmd.apply(to: &score)
        // After: chord A (half) at rtick 0, then alignedRests
        // for the leftover (none since 960=240+720 exactly), then
        // the trailing rest(.half), rest(.eighth) untouched.
        let staff = score.staves[0]
        let m = staff.measures[0]
        let v = m.voices[0]
        guard case .chord(let aa) = v.elements[0] else {
            Issue.record("els[0] not chord"); return
        }
        #expect(aa.duration == .half)
        // Tuplet must be gone (consumed wholesale).
        #expect(v.tuplets.isEmpty)
    }

    @Test("No-op when duration is unchanged")
    func noOpUnchanged() throws {
        var score = score([
            chord(.quarter), rest(.half), rest(.quarter)])
        let snapshot = score
        let cmd = SetChordDuration(
            at: Self.chordID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        #expect(score == snapshot)
    }
}
