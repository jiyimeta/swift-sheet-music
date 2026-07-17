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

    // MARK: - Jumps (hand-derived; shapes cross-checked against
    // MuseScore repeat_tests.cpp scenarios noted per test)

    @Test func daCapoReplaysFromStartOnceOnly() {
        // [m0, m1, m2(D.C.)], Jump{start,end}. Derivation: pass 1
        // plays 0,1,2; at the jump playbackCount(1) >= section
        // plays(1) → honored, (jump,pc1) recorded; jumpTo "start" =
        // section start, playUntil "end" = the section-break element
        // (never marker-matched → section simply runs out);
        // forceFinalRepeat=true but there are no repeats. Second
        // arrival at the jump finds (jump,pc1) already taken → play
        // through to the end. → 0,1,2 | 0,1,2.
        let dc = Jump(jumpTo: "start", playUntil: "end")
        let measures = [Self.measure(), Self.measure(), Self.measure(jumps: [dc])]
        #expect(Self.planIndices(measures) == [0, 1, 2, 0, 1, 2])
    }

    @Test func daCapoAlFineStopsAtFine() {
        // MuseScore repeat07 shape. [m0, m1(Fine), m2, m3(D.C. al
        // Fine)]. Derivation: pass 1 plays 0,1,2,3 (the Fine marker is
        // not the playUntil target yet — playUntil unset); the jump
        // resolves playUntil=findMarker("fine")=m1's marker, jumps to
        // section start with playbackCount=1; on re-reaching the Fine
        // marker: position == playUntil && playbackCount(1) == section
        // plays(1) → final playthrough → stop (continueAt empty).
        // → 0,1,2,3 | 0,1.
        let fine = Marker(kind: .fine) // effectiveLabel "fine"
        let dcAlFine = Jump(jumpTo: "start", playUntil: "fine")
        let measures = [
            Self.measure(),
            Self.measure(markers: [fine]),
            Self.measure(),
            Self.measure(jumps: [dcAlFine]),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 3, 0, 1])
    }

    @Test func dalSegnoAlFineReplaysFromSegno() {
        // [m0, m1(Segno), m2(Fine), m3(D.S. al Fine)]. Derivation:
        // pass 1 plays 0,1,2,3; jump resolves jumpTo=segno(m1),
        // playUntil=fine(m2); performJump walks section start → segno
        // (no repeats/voltas passed) → playbackCount=1; replay starts
        // at m1; at the Fine marker: final playthrough → stop.
        // → 0,1,2,3 | 1,2.
        let segno = Marker(kind: .segno) // effectiveLabel "segno"
        let fine = Marker(kind: .fine)
        let dsAlFine = Jump(jumpTo: "segno", playUntil: "fine")
        let measures = [
            Self.measure(),
            Self.measure(markers: [segno]),
            Self.measure(markers: [fine]),
            Self.measure(jumps: [dsAlFine]),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 3, 1, 2])
    }

    @Test func dalSegnoAlCodaJumpsToCodaAtToCoda() {
        // [m0, m1(Segno), m2(To Coda), m3(D.S. al Coda), m4(Coda)].
        // Labels: toCoda.effectiveLabel=="coda" (jump target of
        // playUntil), coda.effectiveLabel=="codab" (continueAt
        // destination) — MuseScore's markerTypeTable naming.
        // Derivation: pass 1 plays 0,1,2,3; the jump resolves
        // jumpTo=segno(m1), playUntil=toCoda(m2), continueAt=coda(m4);
        // replay 1,2; at To Coda (final playthrough) continueAt fires:
        // performJump(withRepeats:true) to the codab marker → play 4.
        // → 0,1,2,3 | 1,2 | 4.
        let segno = Marker(kind: .segno)
        let toCoda = Marker(kind: .toCoda) // label "coda"
        let coda = Marker(kind: .coda) // label "codab"
        let dsAlCoda = Jump(jumpTo: "segno", playUntil: "coda", continueAt: "codab")
        let measures = [
            Self.measure(),
            Self.measure(markers: [segno]),
            Self.measure(markers: [toCoda]),
            Self.measure(jumps: [dsAlCoda]),
            Self.measure(markers: [coda]),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 3, 1, 2, 4])
    }

    @Test func jumpOnRepeatedMeasureHonoredOnFinalPassOnly() {
        // MuseScore repeat16 ("jump in simple repeat",
        // repeat_tests.cpp:158): m0, m1(Fine), m2, m3(||: + :||x2 +
        // D.C. al Fine). Derivation: pass 1 plays 0,1,2,3; at the
        // jump playbackCount(1) < loop plays(2) → NOT honored; the
        // repeat end rewinds to m3's own start repeat → segment [3];
        // second arrival: playbackCount(2) ≥ 2 → jump honored →
        // replay 0,1 up to Fine. Expected (C++ ref "1;2;3;4; 4; 1;2")
        // → 0,1,2,3 | 3 | 0,1.
        let fine = Marker(kind: .fine)
        let dcAlFine = Jump(jumpTo: "start", playUntil: "fine")
        let measures = [
            Self.measure(),
            Self.measure(markers: [fine]),
            Self.measure(),
            Self.measure(startRepeat: true, endRepeat: 2, jumps: [dcAlFine]),
        ]
        #expect(Self.planIndices(measures) == [0, 1, 2, 3, 3, 0, 1])
    }

    @Test func dalSegnoIntoThreefoldRepeatForcesFinalPass() {
        // MuseScore repeat22 ("DS and ||:3x:||",
        // repeat_tests.cpp:183): m0, m1(Segno), m2(D.S. playUntil
        // end), m3, m4(||: + :||x3), m5. Derivation: pass 1 plays
        // 0,1,2; D.S. honored at pc1 → back to segno(m1) with
        // forceFinalRepeat=true; the un-played repeat end keeps its
        // hit count (repeat22's own re-arm rule applies only to
        // ALREADY-hit ends); replay 1,2,3,4 — the x3 repeat loops
        // twice ([4], [4]) then 5. Expected (C++ "1;2;3; 2;3;4;5; 5;
        // 5;6") → 0,1,2 | 1,2,3,4 | 4 | 4,5.
        let segno = Marker(kind: .segno)
        let ds = Jump(jumpTo: "segno", playUntil: "end")
        let measures = [
            Self.measure(),
            Self.measure(markers: [segno]),
            Self.measure(jumps: [ds]),
            Self.measure(),
            Self.measure(startRepeat: true, endRepeat: 3),
            Self.measure(),
        ]
        #expect(
            Self.planIndices(measures)
                == [0, 1, 2, 1, 2, 3, 4, 4, 4, 5],
        )
    }

    @Test func voltaBetweenSegnoAndDalSegno() {
        // MuseScore repeat12 ("volta between segno & DS",
        // repeat_tests.cpp:132): m0, m1(Segno), m2(||:),
        // m3(volta1 :||x2), m4(volta2), m5(D.S. playUntil end), m6.
        // Derivation: 0,1,2,3 (take 1) | rewind → 2 (volta1 skipped
        // on take 2) | 4,5 (volta2) — D.S. honored at pc2 →
        // forceFinalRepeat re-arms the repeat end to its full count;
        // replay from segno: 1, then the start repeat's desired
        // playbackCount under forceFinalRepeat is the loop's final
        // pass (2) → run restarts, volta1 skipped again → 2 | 4,5,6.
        // Expected (C++ "1;2;3;4; 3; 5;6; 2;3; 5;6;7")
        // → 0,1,2,3 | 2 | 4,5 | 1 | 2 | 4,5,6.
        let segno = Marker(kind: .segno)
        let ds = Jump(jumpTo: "segno", playUntil: "end")
        let measures = [
            Self.measure(),
            Self.measure(markers: [segno]),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, volta: [1]),
            Self.measure(volta: [2]),
            Self.measure(jumps: [ds]),
            Self.measure(),
        ]
        #expect(
            Self.planIndices(measures)
                == [0, 1, 2, 3, 2, 4, 5, 1, 2, 4, 5, 6],
        )
    }

    @Test func playRepeatsTrueReplaysRepeatsAfterJump() {
        // [m0(Segno), m1(||:), m2(:||x2), m3(D.S. playRepeats)].
        // Derivation: pass 1 plays 0,1,2 | 1,2 (repeat) | 3; jump
        // honored at pc2 → performJump(withRepeats:true) resets
        // playbackCount to 1 and the already-hit repeat end is
        // re-armed to 0 hits (NOT forced final) → the repeat replays
        // in full → 0,1,2 | 1,2,3; second jump arrival at pc2 is
        // already taken. → 0,1,2, 1,2,3, 0,1,2, 1,2,3.
        let segno = Marker(kind: .segno)
        let ds = Jump(jumpTo: "segno", playUntil: "end", playRepeats: true)
        let measures = [
            Self.measure(markers: [segno]),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2),
            Self.measure(jumps: [ds]),
        ]
        #expect(
            Self.planIndices(measures)
                == [0, 1, 2, 1, 2, 3, 0, 1, 2, 1, 2, 3],
        )
    }

    @Test func playRepeatsFalsePlaysFinalPassAfterJump() {
        // Same score, playRepeats=false (the MuseScore default):
        // after the jump forceFinalRepeat=true → the start repeat
        // restarts the run at the loop's final pass (2) and the
        // re-armed repeat end doesn't loop → the repeated passage
        // plays ONCE. → 0,1,2, 1,2,3, 0, 1,2,3.
        let segno = Marker(kind: .segno)
        let ds = Jump(jumpTo: "segno", playUntil: "end")
        let measures = [
            Self.measure(markers: [segno]),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2),
            Self.measure(jumps: [ds]),
        ]
        #expect(
            Self.planIndices(measures)
                == [0, 1, 2, 1, 2, 3, 0, 1, 2, 3],
        )
    }

    @Test func incompleteJumpIsIgnored() {
        // MuseScore repeat13/26 spirit: a jump whose jumpTo label
        // resolves nowhere is skipped; playback continues linearly.
        let broken = Jump(jumpTo: "segno", playUntil: "end")
        let measures = [Self.measure(), Self.measure(jumps: [broken])]
        #expect(Self.planIndices(measures) == [0, 1])
    }
}
