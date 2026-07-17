import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `PlaybackUnroll` maps the sequencer's UNROLLED tick space (the
/// rendered SMF, repeats + jumps expanded) back to NOTATED score
/// ticks (`PlaybackTimeline` coordinates) — the Swift analog of
/// MuseScore's `RepeatList::utick2tick`.
struct PlaybackUnrollTests {
    private static let division = 480
    private static let span = 1920 // whole note in 4/4 @ 480

    private static func measure(
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
    ) -> Measure {
        Measure(
            voices: [Voice(elements: [.chord(Chord(
                duration: .whole,
                notes: [Note(pitch: 60, tpc: 14)],
            ))])],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            markers: markers,
            jumps: jumps,
        )
    }

    private static func score(_ measures: [Measure]) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        return Score(division: division, parts: [part])
    }

    @Test func repeatSecondPassMapsBackToNotatedMeasure() {
        // [m0, m1(||:x2:||), m2] → plan [0,1,1,2]; unrolled m1'
        // (second pass) starts at 3840 but notates at 1920. m1 needs
        // BOTH startRepeat and endRepeat — an end-repeat alone loops
        // back to the implicit section start (m0), not to itself; see
        // PlaybackUnwindTests.plainRepeatUnrollsTwice.
        //
        // swift-sheet-music note: the original task brief specified
        // `Self.measure(endRepeat: 2)` here (no `startRepeat: true`),
        // which — per the semantics this same file's
        // `edgesClampAndExtrapolate` pins — loops back to m0 and
        // yields plan [0,1,0,1,2] (5 plays, total 5*span), not the
        // [0,1,1,2] this test's comment describes. Adding
        // `startRepeat: true` to m1 was the fix that makes the actual
        // plan match the comment and every numeric expectation below
        // unchanged; see task-12-report.md for the verification.
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(), Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ]))
        #expect(unroll.totalUnrolledTicks == 4 * Self.span)
        #expect(unroll.notatedTick(fromUnrolled: 0) == 0)
        #expect(unroll.notatedTick(fromUnrolled: 2000) == 2000) // first pass
        #expect(unroll.notatedTick(fromUnrolled: 3840) == 1920) // 2nd pass start
        #expect(unroll.notatedTick(fromUnrolled: 4000) == 2080) // 2nd pass +160
        #expect(unroll.notatedTick(fromUnrolled: 5760) == 3840) // m2
    }

    @Test func jumpTargetMapsToItsNotatedMeasure() {
        // D.S. al Fine: segno m1, fine m2, jump m3 → plan
        // [0,1,2,3, 1,2]. The 5th measure-play (unrolled 4*1920)
        // notates at m1 (1920).
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(),
            Self.measure(markers: [Marker(kind: .segno)]),
            Self.measure(markers: [Marker(kind: .fine)]),
            Self.measure(jumps: [Jump(jumpTo: "segno", playUntil: "fine")]),
        ]))
        #expect(unroll.totalUnrolledTicks == 6 * Self.span)
        #expect(unroll.notatedTick(fromUnrolled: 4 * Self.span) == Self.span)
        #expect(unroll.notatedTick(fromUnrolled: 5 * Self.span) == 2 * Self.span)
        #expect(
            unroll.notatedTick(fromUnrolled: 5 * Self.span + 100)
                == 2 * Self.span + 100,
        )
    }

    @Test func edgesClampAndExtrapolate() {
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(), Self.measure(endRepeat: 2),
        ]))
        // plan [0,1,0,1]; total 4*1920.
        #expect(unroll.notatedTick(fromUnrolled: -5) == 0)
        // Past the end: extrapolate from the last span (mirrors
        // utick2tick's last-segment fallthrough, repeatlist.cpp:266).
        #expect(
            unroll.notatedTick(fromUnrolled: 4 * Self.span + 10)
                == 2 * Self.span + 10,
        )
    }

    @Test func fractionalVariantPreservesOffset() {
        // Same shape as repeatSecondPassMapsBackToNotatedMeasure —
        // m1 needs startRepeat too; see the note there.
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(), Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ]))
        #expect(unroll.notatedTick(fromUnrolled: 4000.5) == 2080.5)
        #expect(unroll.notatedTick(fromUnrolled: -1.5) == 0)
    }

    @Test func identityPassesThrough() {
        #expect(PlaybackUnroll.identity.notatedTick(fromUnrolled: 1234) == 1234)
        #expect(PlaybackUnroll.identity.notatedTick(fromUnrolled: 12.5) == 12.5)
        #expect(PlaybackUnroll.identity.totalUnrolledTicks == 0)
    }

    // MARK: - unrolledTicks(forNotated:) — the inverse projection used to
    // unroll the BODY metronome track so it doesn't go silent on a
    // repeat's 2nd pass (or any jump).

    @Test func unrolledTicksMapsRepeatedMeasureToBothOccurrences() {
        // Same shape as repeatSecondPassMapsBackToNotatedMeasure — plan
        // [0,1,1,2]: m1 (notated [1920, 3840)) is played twice, so a
        // notated tick inside it has TWO unrolled occurrences (first pass
        // at +0, second pass at +2*span).
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(), Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ]))
        #expect(unroll.unrolledTicks(forNotated: 2020) == [2020, 3940])
    }

    @Test func unrolledTicksMapsSinglePassMeasureToOneOccurrence() {
        let unroll = MidiRenderer.playbackUnroll(score: Self.score([
            Self.measure(), Self.measure(startRepeat: true, endRepeat: 2), Self.measure(),
        ]))
        // m0 (notated [0, 1920)) is played once — a single occurrence.
        #expect(unroll.unrolledTicks(forNotated: 100) == [100])
        // m2 (notated [3840, 5760)) comes after the repeat, at unrolled
        // [5760, 7680) — also a single occurrence.
        #expect(unroll.unrolledTicks(forNotated: 3890) == [5810])
    }

    @Test func unrolledTicksIdentityPassesThrough() {
        // A plan-less score (`PlaybackUnroll.identity`) has no spans; the
        // projection must still return the input tick so a beat is never
        // silently dropped for a score without a computed repeat plan.
        #expect(PlaybackUnroll.identity.unrolledTicks(forNotated: 1234) == [1234])
    }
}
