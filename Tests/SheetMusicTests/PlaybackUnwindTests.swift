import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Unrolled playback order assertions against hand-derived expected
/// sequences. Scenario shapes mirror MuseScore's repeat_tests.cpp
/// (referenced per test); the assertions run on OUR engine only.
struct PlaybackUnwindTests {
    private static let division = 480
    /// Whole note in 4/4 at division 480.
    private static let span = 1920

    private static func measure(
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        sectionBreak: Bool = false,
        volta: [Int]? = nil,
        voltaMeasures: Int = 1,
    ) -> Measure {
        var elements: [VoiceElement] = []
        if let volta {
            elements.append(.spanner(Spanner(
                kind: .volta, rawType: "Volta",
                nextMeasuresOffset: voltaMeasures, voltaEndings: volta,
            )))
        }
        elements.append(.chord(Chord(
            duration: .whole,
            notes: [Note(pitch: 60, tpc: 14)],
        )))
        return Measure(
            voices: [Voice(elements: elements)],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            markers: markers,
            jumps: jumps,
            sectionBreak: sectionBreak,
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

    private static func plan(_ measures: [Measure]) -> [MidiRenderer.PlaybackEntry] {
        RepeatUnwinder.plan(navigation: ScoreNavigation(score: score(measures)))
    }

    private static func planIndices(_ measures: [Measure]) -> [Int] {
        plan(measures).map(\.measureIndex)
    }

    // MARK: - Repeats / voltas (parity with the legacy walk)

    @Test func plainRepeatUnrollsTwice() {
        // [m0, m1(:||x2)] → 0,1 | 0,1.
        let measures = [Self.measure(), Self.measure(endRepeat: 2)]
        #expect(Self.planIndices(measures) == [0, 1, 0, 1])
    }

    @Test func repeatBarlinesWithExplicitStart() {
        // MuseScore repeat01 shape: m0 ||: m1 m2 :|| m3 m4 m5
        // → 0,1,2 | 1,2,3,4,5.
        let measures = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2),
            Self.measure(), Self.measure(), Self.measure(),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 1, 2, 3, 4, 5])
    }

    @Test func chainedRepeatsAccumulateOntoOneStart() {
        // MuseScore repeat05 shape: m0 ||: m1 m2(:||x3) m3(:||x2) m4 m5.
        // The section RS accumulates 1+(3-1)+(2-1)=4 total plays:
        // pass1: 0,1,2 (inner RE hit 1<3 → rewind, pc2)
        // pass2: 1,2   (inner RE hit 2<3 → rewind, pc3)
        // pass3: 1,2,3 (inner exhausted; outer RE hit 1<2 → rewind, pc4)
        // pass4: 1,2,3,4,5 (both exhausted).
        let measures = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 3),
            Self.measure(endRepeat: 2),
            Self.measure(), Self.measure(),
        ]
        #expect(
            Self.planIndices(measures)
                == [0, 1, 2, 1, 2, 1, 2, 3, 1, 2, 3, 4, 5],
        )
    }

    @Test func simpleVoltaTakesFirstThenSecondEnding() {
        // MuseScore repeat06 shape: m0 ||: m1 m2(volta1 :||x2) m3(volta2) m4 m5
        // → 0,1,2 | 1, 3,4,5 (volta1 skipped on take 2).
        let measures = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, volta: [1]),
            Self.measure(volta: [2]),
            Self.measure(), Self.measure(),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 1, 3, 4, 5])
    }

    @Test func sectionBreakResetsRepeatState() {
        // [m0(:||x2 + sectionBreak), m1] → 0 | 0 | 1.
        let measures = [
            Self.measure(endRepeat: 2, sectionBreak: true),
            Self.measure(),
        ]
        #expect(Self.planIndices(measures) == [0, 0, 1])
    }

    @Test func tickOffsetsAccumulateCanonicalSpans() {
        let measures = [Self.measure(), Self.measure(endRepeat: 2)]
        #expect(
            Self.plan(measures).map(\.tickOffset)
                == [0, Self.span, 2 * Self.span, 3 * Self.span],
        )
    }

    @Test func iterationStartFlagsNonLinearEntries() {
        // Plain repeat: the loop-back entry (m0 after m1) is flagged.
        let measures = [Self.measure(), Self.measure(endRepeat: 2)]
        #expect(
            Self.plan(measures).map(\.isIterationStart)
                == [false, false, true, false],
        )
    }

    @Test func sequentialRepeatGroupsResetPlaybackCountPerGroup() {
        // Review finding (Task 9): pins the intentional divergence from
        // the deleted hand-rolled playbackPlan, whose `take` counter
        // never reset across repeat groups and so wrongly skipped
        // volta 1 in the second group. RepeatUnwinder resets
        // playbackCount at every REPEAT_START (repeatlist.cpp:921-933),
        // which is what MuseScore actually does.
        //
        // Shape: ||: m0 :||  ||: m2 [volta1: m3(:||x2)] :||  [volta2: m4]
        //   m0 startRepeat, m1 endRepeat(2)          — group 1
        //   m2 startRepeat, m3 volta[1] endRepeat(2), m4 volta[2] — group 2
        //
        // Hand-derivation:
        // group 1 (plain repeat, pc 1→2): 0,1 | 0,1.
        // group 2's repeatStart (m2) resets playbackCount to 1 — the
        // divergence point.
        //   pass1 (pc=1): m2, m3 — volta1 taken (pc=1 ∈ [1]); repeat-end
        //     rewinds (pc 1<loopPlays 2, hits 1<notated 2) back to m2.
        //   pass2 (pc=2): m2 again; volta1 SKIPPED (pc=2 ∉ [1]) so the
        //     walk jumps straight past m3 to volta2's m4 (pc=2 ∈ [2]);
        //     section ends there.
        // → 0,1,0,1,2,3,2,4.
        let measures = [
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, volta: [1]),
            Self.measure(volta: [2]),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 0, 1, 2, 3, 2, 4])
    }

    @Test func multiMeasureVoltaSkipsBothBracketMeasuresOnSecondPass() {
        // Review finding (Task 9), minor coverage gap: a two-measure
        // volta 1 bracket (voltaMeasures: 2) exercises the
        // skip-across-bracket + restart-at-(voltaEndMeasure+1) path in
        // `processVoltaStart`. Because the endRepeat barline sits
        // INSIDE the skipped bracket (on m3, the bracket's second and
        // last measure), this also pins the second divergence from the
        // deleted playbackPlan: the old walk counted that endRepeat
        // when skipping past it; the new one jumps straight to
        // `.voltaEnd` without reprocessing it.
        //
        // Shape: m0  ||: m1 [volta1(2 measures): m2 m3(:||x2)] [volta2: m4] m5 m6
        //
        // Hand-derivation:
        //   m0 plays once.
        //   pass1 (pc=1): m1, m2, m3 — volta1 taken (pc=1 ∈ [1]);
        //     repeat-end rewinds (pc 1<2, hits 1<2) back to m1.
        //   pass2 (pc=2): m1 again; volta1 SKIPPED (pc=2 ∉ [1]) — the
        //     walk advances straight to the voltaEnd on m3 (never
        //     revisiting m3's repeatEnd), and restarts the run at
        //     voltaEndMeasure + 1 = m4; volta2 taken (pc=2 ∈ [2]);
        //     m5, m6 follow to the section break.
        // → 0,1,2,3,1,4,5,6.
        let measures = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(volta: [1], voltaMeasures: 2),
            Self.measure(endRepeat: 2),
            Self.measure(volta: [2]),
            Self.measure(), Self.measure(),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 3, 1, 4, 5, 6])
    }

    @Test func legacyPlaybackPlanWrapperMatchesUnwinder() {
        // The single-staff wrapper must produce the identical plan
        // for repeat/volta-only input (its navigation strips jumps).
        let measures = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, volta: [1]),
            Self.measure(volta: [2]),
            Self.measure(),
        ]
        let wrapper = MidiRenderer.playbackPlan(for: measures, division: Self.division)
        let direct = RepeatUnwinder.plan(
            navigation: ScoreNavigation(staffMeasures: measures, division: Self.division),
        )
        #expect(wrapper == direct)
        #expect(wrapper.map(\.measureIndex) == [0, 1, 2, 1, 3, 4])
    }
}
