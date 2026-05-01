@testable import SheetMusicCore
import Testing

@Suite("SetRestDuration")
struct SetRestDurationTests {
    private func chord(_ d: NoteDuration = .quarter, _ p: Int = 60) -> VoiceElement {
        .chord(Chord(duration: d, notes: [Note(pitch: p, tpc: 14)]))
    }
    private func rest(_ d: NoteDuration) -> VoiceElement {
        .rest(Rest(duration: d))
    }
    private func score(_ elements: [VoiceElement]) -> Score {
        Score(division: 480, staves: [
            StaffContent(id: 1, measures: [
                Measure(voices: [Voice(elements: elements)])
            ])
        ])
    }
    private func first(_ score: Score) -> [VoiceElement] {
        score.staves[0].measures[0].voices[0].elements
    }
    private static let restID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 0)

    @Test("Shorten quarter rest → eighth fills leftover with eighth rest")
    func shortenQuarterToEighth() throws {
        var score = score([rest(.quarter), rest(.half),
                           rest(.quarter)])
        let cmd = SetRestDuration(
            at: Self.restID, duration: .eighth)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        guard case .rest(let r0) = els[0] else {
            Issue.record("els[0] not rest"); return
        }
        #expect(r0.duration == .eighth)
        guard case .rest(let r1) = els[1] else {
            Issue.record("els[1] not rest"); return
        }
        #expect(r1.duration == .eighth)
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

    @Test("Shorten whole rest → eighth is rhythm-aligned")
    func shortenWholeToEighthAligned() throws {
        var score = score([rest(.whole)])
        let cmd = SetRestDuration(
            at: Self.restID, duration: .eighth)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // rest(.eighth), rest(.eighth), rest(.quarter), rest(.half)
        #expect(els.count == 4)
        let durations = els.compactMap { el -> NoteDuration? in
            if case .rest(let r) = el { return r.duration }
            return nil
        }
        #expect(durations == [.eighth, .eighth, .quarter, .half])
    }

    @Test("Lengthen rest into next rest exactly")
    func lengthenIntoRest() throws {
        var score = score([rest(.eighth), rest(.eighth),
                           rest(.half), rest(.quarter)])
        // Lengthen first rest to quarter; should consume the
        // following eighth rest.
        let cmd = SetRestDuration(
            at: Self.restID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // Expected: rest(.quarter), rest(.half), rest(.quarter)
        #expect(els.count == 3)
        guard case .rest(let r0) = els[0] else {
            Issue.record("els[0]"); return
        }
        #expect(r0.duration == .quarter)
    }

    @Test("Lengthen rest into chord → chord-clone overshoot")
    func lengthenIntoChord() throws {
        // rest(eighth), chord(half pitch=64), rest(quarter), rest(eighth)
        var score = score([rest(.eighth), chord(.half, 64),
                           rest(.quarter), rest(.eighth)])
        // Lengthen rest to quarter (need +240). Consume 240 of the
        // half-chord (960 → leftover 720). Overshoot becomes tied
        // clones of the chord (pitch 64): quarter at rtick 480 +
        // eighth at rtick 960.
        let cmd = SetRestDuration(
            at: Self.restID, duration: .quarter)
        _ = try cmd.apply(to: &score)
        let els = first(score)
        // Expected: rest(quarter), chord(quarter, p64, tieFwd),
        //           chord(eighth, p64, tieBack), rest(quarter),
        //           rest(eighth)
        #expect(els.count == 5)
        guard case .rest(let r0) = els[0] else {
            Issue.record("els[0]"); return
        }
        #expect(r0.duration == .quarter)
        guard case .chord(let c1) = els[1] else {
            Issue.record("els[1]"); return
        }
        #expect(c1.duration == .quarter)
        #expect(c1.notes.first?.pitch == 64)
        #expect(c1.notes.first?.tieForward == 1)
        #expect(c1.notes.first?.tieBack == nil)
        guard case .chord(let c2) = els[2] else {
            Issue.record("els[2]"); return
        }
        #expect(c2.duration == .eighth)
        #expect(c2.notes.first?.tieBack == 1)
    }

    @Test("Inverse round-trips for shorten")
    func shortenRoundTrip() throws {
        var score = score([rest(.quarter), rest(.half),
                           rest(.quarter)])
        let snapshot = score
        let cmd = SetRestDuration(
            at: Self.restID, duration: .eighth)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("Inverse round-trips for lengthen-into-chord")
    func lengthenIntoChordRoundTrip() throws {
        var score = score([rest(.eighth), chord(.half, 64),
                           rest(.quarter), rest(.eighth)])
        let snapshot = score
        let cmd = SetRestDuration(
            at: Self.restID, duration: .quarter)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("Refuses lengthening past measure end")
    func refusesPastMeasureEnd() {
        var score = score([rest(.quarter), rest(.eighth)])
        let cmd = SetRestDuration(
            at: Self.restID, duration: .whole)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("Refuses on a chord (wrong target type)")
    func refusesOnChord() {
        var score = score([chord(.quarter)])
        let cmd = SetRestDuration(
            at: Self.restID, duration: .eighth)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
