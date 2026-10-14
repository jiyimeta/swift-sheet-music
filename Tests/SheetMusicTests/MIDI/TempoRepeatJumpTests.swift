@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// After a repeat jump the SMF re-states the tempo in force at the target's downbeat — the notated tempo MuseScore's
/// playback and the cursor both play there — when the track plays another tempo there and no marking or ramp step on
/// that downbeat states it already (import-fidelity F2.10). A fermata's hold plays on every pass of its own bar, and
/// on no other: a hold on a downbeat opens where that bar starts, whatever bar came before it.
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
        withRepeats(score, start: start, ends: [(measure: end, plays: 2)])
    }

    /// `score` with a start repeat on measure `start` and, on each of `ends`, an end repeat played `plays` times.
    private static func withRepeats(_ score: Score, start: Int, ends: [(measure: Int, plays: Int)]) -> Score {
        var score = score
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[start].startRepeat = true
                for end in ends {
                    staff.measures[end.measure].endRepeatCount = end.plays
                }
            }
        }
        return score
    }

    /// `score` with measure `measure`'s voice replaced by `elements`. Not for measure 0, which carries the meter.
    private static func withVoice(_ score: Score, measure: Int, _ elements: [VoiceElement]) -> Score {
        var score = score
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[measure].voices[0] = Voice(elements: IdentifiedArray(elements))
            }
        }
        return score
    }

    /// The fixtures' beat: a quarter-note middle C.
    private static var beat: VoiceElement {
        .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
    }

    /// A fermata holding the chord after it ×1.5: 120 BPM plays as 80, 750000 µs per quarter.
    private static var fermata: VoiceElement {
        .fermata(Fermata(subtype: "fermataAbove"))
    }

    /// A bar of four beats held by a fermata on the first.
    private static var heldDownbeatBar: [VoiceElement] {
        [fermata, beat, beat, beat, beat]
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
        // Both tick-0 metas are the score's opening, not the jump: the first track's header writes the 120 BPM
        // default (`MidiRenderer.headerEvents`), then the voice walk writes m0's ♩ = 90 marking. The jump back to m1
        // at 3840 lands on ♩ = 90, which is playing, so it writes nothing.
        #expect(try Self.tempos(score).map(\.tick) == [0, 0])
    }

    @Test("a fermata closing the bar before the jump does not carry the next bar's tempo into the target")
    func fermataCloseBeforeTheJumpIsOverridden() throws {
        // m0 ♩ = 120 | ‖: m1 | m2, a fermata (×1.5) on its last beat :‖ | m3 ♩ = 90. m0 0, m1 1920, m2 3840, back to
        // m1 at 5760, m2 again 7680, m3 9600. The hold is [5280, 5760) in notation and is replayed with its bar: it
        // opens at 2 / 1.5 bps (750000) at 5280 and 9120, and closes at 5760 and 9600 on the tempo in force where it
        // ends in notation — m3's downbeat, ♩ = 90 (666667). The walk's own sequence stands at ♩ = 120, the target's
        // tempo, so only the close says the track plays ♩ = 90 at the jump: the re-statement follows it on 5760 and
        // wins. At 9600 the close and m3's marking agree.
        let score = Self.withVoice(
            TempoMapFixtures.score(
                measures: 4, lane: [
                    TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
                    TempoMapFixtures.tempo(3, 0, Tempo(beatsPerSecond: 1.5)),
                ], notes: true,
            ),
            measure: 2, [Self.beat, Self.beat, Self.beat, Self.fermata, Self.beat],
        )
        let tempos = try Self.tempos(Self.withRepeat(score, from: 1, to: 2))
        #expect(tempos.map(\.tick) == [0, 0, 5280, 5760, 5760, 9120, 9600, 9600])
        #expect(tempos.map(\.micros) == [500_000, 500_000, 750_000, 666_667, 500_000, 750_000, 666_667, 666_667])
    }

    @Test("a jump into the middle of a gradual change re-states the step in force at the target")
    func midRampTargetGetsTheStepInForce() throws {
        // m0 ♩ = 120 | m1 rit. (×0.75) for a bar and a quarter | ‖: m2 :‖ | m3. The change runs 2400 ticks from 1920 in
        // max(8, 2400 / 480) = 8 linear steps of 300 ticks, step i at 2 - 0.5 i / 8 bps. m2's downbeat (3840) falls
        // between step 6 (3720, 1.625 bps = 615385) and step 7 (4020, 1.5625 bps = 640000); step 8 (4320, 1.5 bps =
        // 666667) is the last. Back to m2 at 5760 from step 8: the step in force on m2's downbeat, step 6, is
        // re-stated, then m2's own steps 7 and 8 follow at 5940 and 6240.
        let rit = Spanner(
            kind: .gradualTempoChange, rawType: Spanner.Kind.gradualTempoChange.rawValue, nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            gradualTempoChange: Spanner.GradualTempoChangePayload(type: .ritardando),
        )
        let score = Self.withRepeat(
            TempoMapFixtures.score(
                measures: 4, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))], notes: true,
                ramps: [(measure: 1, spanner: rit)],
            ),
            from: 2, to: 2,
        )
        let tempos = try Self.tempos(score).filter { $0.tick >= 3720 }
        #expect(tempos.map(\.tick) == [3720, 4020, 4320, 5760, 5940, 6240])
        #expect(tempos.map(\.micros) == [615_385, 640_000, 666_667, 615_385, 640_000, 666_667])
    }

    @Test("each jump of a repeat nested in another re-states the tempo where it lands")
    func nestedRepeatReestablishesTempoAtEveryJump() throws {
        // MuseScore's repeat05 shape: m0 ♩ = 120 | ‖: m1 | m2, ♩ = 60 on beat 3, :‖ ×3 | m3 ♩ = 90 :‖ ×2 | m4 | m5.
        // Both end repeats return to m1 — m0 m1 m2 | m1 m2 | m1 m2 m3 | m1 m2 m3 m4 m5, a bar every 1920 ticks, the
        // plan `PlaybackUnwindTests.chainedRepeatsAccumulateOntoOneStart` pins. Each return to m1 (5760 and 9600 from
        // ♩ = 60, 15360 from ♩ = 90) re-states ♩ = 120; every pass through m2 and m3 states their own markings.
        let score = Self.withRepeats(
            TempoMapFixtures.score(
                measures: 6, lane: [
                    TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
                    TempoMapFixtures.tempo(2, 2, Tempo(beatsPerSecond: 1)),
                    TempoMapFixtures.tempo(3, 0, Tempo(beatsPerSecond: 1.5)),
                ], notes: true,
            ),
            start: 1, ends: [(measure: 2, plays: 3), (measure: 3, plays: 2)],
        )
        let tempos = try Self.tempos(score)
        #expect(tempos.map(\.tick) == [0, 0, 4800, 5760, 8640, 9600, 12480, 13440, 15360, 18240, 19200])
        #expect(tempos.map(\.micros) == [
            500_000, 500_000, 1_000_000, 500_000, 1_000_000, 500_000,
            1_000_000, 666_667, 500_000, 1_000_000, 666_667,
        ])
    }

    @Test("a fermata on the bar after :‖ holds that bar alone, not the repeated pass")
    func heldBarAfterTheRepeatLeavesTheSecondPassAlone() throws {
        // m0 ♩ = 120 | ‖: m1 :‖ | m2, a fermata on its first beat: m0 0, m1 1920, back to m1 at 3840, m2 5760. The hold
        // is [3840, 4320) in notation. Its open sits on the m1 | m2 barline and belongs to m2, so it fires once, at
        // 5760, closed at 6240. Given to m1, the bar ending there, it also fired at the jump back (3840), and all of
        // m1's second pass played at 80.
        let score = Self.withRepeat(
            Self.withVoice(
                TempoMapFixtures.score(
                    measures: 3, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))], notes: true,
                ),
                measure: 2, Self.heldDownbeatBar,
            ),
            from: 1, to: 1,
        )
        let tempos = try Self.tempos(score)
        #expect(tempos.map(\.tick) == [0, 0, 5760, 6240])
        #expect(tempos.map(\.micros) == [500_000, 500_000, 750_000, 500_000])
    }

    @Test("a fermata on a repeat target's downbeat holds on the pass that jumps there too")
    func heldDownbeatOfTheTargetHoldsOnEveryPass() throws {
        // m0 ♩ = 120 | ‖: m1, a fermata on its first beat | m2 :‖ | m3: m0 0, m1 1920, m2 3840, back to m1 at 5760, m2
        // 7680, m3 9600. The open on the m0 | m1 barline belongs to m1 and fires on both passes, at 1920 and 5760, each
        // closed a beat later. Given to m0 it fired only at 1920, where m0 ends, and the pass that jumped back did not
        // hold. At 5760 nothing is re-stated: the first pass's close left ♩ = 120 playing.
        let score = Self.withRepeat(
            Self.withVoice(
                TempoMapFixtures.score(
                    measures: 4, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))], notes: true,
                ),
                measure: 1, Self.heldDownbeatBar,
            ),
            from: 1, to: 2,
        )
        let tempos = try Self.tempos(score)
        #expect(tempos.map(\.tick) == [0, 0, 1920, 2400, 5760, 6240])
        #expect(tempos.map(\.micros) == [500_000, 500_000, 750_000, 500_000, 750_000, 500_000])
    }

    @Test("a fermata on a bar's first chord opens where that bar starts in the unrolled sequence")
    func heldDownbeatOpensWhereItsBarStarts() throws {
        // MuseScore's repeat06 shape — m0 ♩ = 120 | ‖: m1 | m2 [1. :‖ | m3 [2., a fermata on its first beat | m4 | m5 —
        // plays m0 m1 m2 | m1 m3 m4 m5 (`PlaybackUnwindTests.simpleVoltaTakesFirstThenSecondEnding`), so m3 starts at
        // 7680, after m1, and never follows m2. The open on the m2 | m3 barline fires there, closed at 8160. Given to
        // m2 it fired at 5760, where m2 ends and the jump back to m1 begins, and held all of m1's second pass.
        var score = TempoMapFixtures.score(
            measures: 6, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))], notes: true,
        )
        score = Self.withVoice(score, measure: 2, [Self.volta(ending: 1), Self.beat, Self.beat, Self.beat, Self.beat])
        score = Self.withVoice(score, measure: 3, [Self.volta(ending: 2)] + Self.heldDownbeatBar)
        let tempos = try Self.tempos(Self.withRepeat(score, from: 1, to: 2))
        #expect(tempos.map(\.tick) == [0, 0, 7680, 8160])
        #expect(tempos.map(\.micros) == [500_000, 500_000, 750_000, 500_000])
    }

    /// A one-bar volta bracket for `ending`, as `PlaybackUnwindTests` writes one.
    private static func volta(ending: Int) -> VoiceElement {
        .spanner(Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [ending]))
    }
}
