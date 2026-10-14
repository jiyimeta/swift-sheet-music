@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// After a repeat jump the SMF re-states the tempo in force at the target's downbeat — the notated tempo MuseScore's
/// playback and the cursor both play there — when the sequence stands at another tempo and no marking or ramp step on
/// that downbeat states it already (import-fidelity F2.10).
@Suite("Tempo after a repeat jump")
struct TempoRepeatJumpTests {
    /// m0 ♩ = 120 | ‖: m1 | m2 rit. :‖ (×2) | m3 — a middle C per beat.
    private static func ritBeforeRepeat(markingAtTarget: Bool = false) -> Score {
        var lane = [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))]
        if markingAtTarget {
            lane.append(TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 2)))
        }
        let score = TempoMapFixtures.score(
            measures: 4, lane: lane, notes: true,
            ramps: [(measure: 2, spanner: TempoMapFixtures.ritardando(measures: 1))],
        )
        return withRepeat(score, from: 1, to: 2)
    }

    private static func withRepeat(_ score: Score, from start: Int, to end: Int) -> Score {
        var score = score
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[start].startRepeat = true
                staff.measures[end].endRepeatCount = 2
            }
        }
        return score
    }

    /// The first track's tempo metas, as (tick, µs per quarter).
    private static func tempos(_ score: Score) throws -> [(tick: Int, micros: Int)] {
        try MidiRenderer.render(score: score).tracks[0].events.compactMap { event in
            guard case let .meta(.tempo(micros)) = event.event else { return nil }
            return (event.tick, micros)
        }
    }

    @Test("the jump back re-states the tempo in force where the repeat starts")
    func jumpReestablishesTempo() throws {
        // m0 0–1920, m1 1920–3840, m2 3840–5760 (rit. 120 → 90), back to m1 at 5760, m2 again 7680–9600, m3 9600.
        let tempos = try Self.tempos(Self.ritBeforeRepeat())
        #expect(tempos.contains { $0.tick == 5760 && $0.micros == 500_000 })
        #expect(tempos.contains { $0.tick == 9600 && $0.micros == 666_667 })
    }

    @Test("a target whose marking states the tempo gets no second event")
    func noRedundantTempoAtMarkedTarget() throws {
        let atJump = try Self.tempos(Self.ritBeforeRepeat(markingAtTarget: true)).filter { $0.tick == 5760 }
        #expect(atJump.map(\.micros) == [500_000])
    }

    @Test("a jump that lands at the tempo already playing adds nothing")
    func noEventWhenTheTempoAlreadyPlays() throws {
        let score = Self.withRepeat(
            TempoMapFixtures.score(
                measures: 3, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 1.5))], notes: true,
            ),
            from: 1, to: 1,
        )
        #expect(try Self.tempos(score).map(\.tick) == [0, 0])
    }
}
