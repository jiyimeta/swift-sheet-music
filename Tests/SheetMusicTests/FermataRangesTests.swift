import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

// Tuple arrays aren't `Equatable`, so define the test-local comparison
// here. SwiftLint's `static_operator` rule is intentionally bypassed —
// you can't add a static operator to the built-in `Array<(Int, Int)>`.
// swiftlint:disable:next static_operator
private func == (lhs: [(Int, Int)], rhs: [(Int, Int)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

struct FermataRangesTests {
    private func chord(_ pitch: Int = 60, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private func rest(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }

    private func fermata(
        _ subtype: String = "fermataAbove",
        stretch: Double? = nil,
    ) -> VoiceElement {
        .fermata(Fermata(subtype: subtype, timeStretch: stretch))
    }

    private func staff(_ voiceElements: [[VoiceElement]]) -> Staff {
        let voices = voiceElements.map { Voice(elements: $0) }
        return Staff(measures: [Measure(voices: voices)])
    }

    /// The anchoring rule under test lives in `Score.fermataHolds()` — one derivation shared by the
    /// renderer's tempo bookends and the notated-time API. Every fixture here is a single measure,
    /// so a hold's bar-relative onset is also its absolute tick.
    private func holds(of s: Staff) -> [FermataRange] {
        let score = Score(
            division: 480,
            parts: [Part(id: "p", instrument: Instrument(id: "i"), staves: [s])],
        )
        return score.fermataHolds().map {
            FermataRange(
                startTick: $0.startTickInMeasure,
                endTick: $0.startTickInMeasure + $0.ticks,
                stretch: $0.stretch,
            )
        }
    }

    // MARK: anchor: forward search (canonical MusicXML layout)

    @Test func forwardAnchorPicksNextChord() {
        let s = staff([[
            chord(60), // tick 0..480
            fermata("fermataAbove"), // anchors to D4
            chord(62), // tick 480..960
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    @Test func forwardAnchorAcrossDynamicAndKeySig() {
        let s = staff([[
            chord(60),
            fermata("fermataAbove"),
            .dynamic(Dynamic(subtype: "mf", velocity: 64)), // skipped
            chord(62),
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    // MARK: anchor: backward fallback (MSCX after-chord layout)

    @Test func backwardFallbackPicksPreviousChord() {
        let s = staff([[
            chord(60), // tick 0..480
            fermata("fermataAbove"), // no chord after → fall back to C4
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: anchor: no chord → drop silently

    @Test func orphanFermataDropped() {
        let s = staff([[
            fermata("fermataAbove"), // no chord at all
        ]])
        let ranges = holds(of: s)
        #expect(ranges.isEmpty)
    }

    // MARK: stretch: subtype default vs explicit

    @Test func longSubtypeUsesDefaultStretch() {
        let s = staff([[
            fermata("fermataLongAbove"),
            chord(60),
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }

    @Test func explicitStretchOverridesSubtypeDefault() {
        let s = staff([[
            fermata("fermataAbove", stretch: 2.5),
            chord(60),
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.5)])
    }

    // MARK: rest fermata applies (grand pause)

    @Test func restFermataYieldsRange() {
        let s = staff([[
            fermata("fermataAbove"),
            rest(.quarter),
        ]])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: dedupe identical ranges across voices

    @Test func sameRangeAcrossVoicesDedupedToMaxStretch() {
        let s = staff([
            [fermata("fermataAbove"), chord(60)], // stretch 1.5 on [0,480)
            [fermata("fermataLongAbove"), chord(60)], // stretch 2.0 on [0,480)
        ])
        let ranges = holds(of: s)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }

    // MARK: TempoTimeline lookup

    @Test func tempoTimelineLookupPicksLastEntryAtOrBeforeTick() {
        let timeline = TempoTimeline(entries: [
            (tick: 0, bps: 2.0), // 120 BPM
            (tick: 480, bps: 3.0), // 180 BPM
            (tick: 1920, bps: 1.5), // 90 BPM
        ])
        #expect(timeline.bps(at: 0) == 2.0)
        #expect(timeline.bps(at: 200) == 2.0)
        #expect(timeline.bps(at: 480) == 3.0)
        #expect(timeline.bps(at: 1000) == 3.0)
        #expect(timeline.bps(at: 1920) == 1.5)
        #expect(timeline.bps(at: 9999) == 1.5)
    }

    @Test func tempoTimelineDefaultIsTwoBps() {
        let s = staff([[chord(60)]])
        let timeline = TempoTimeline.build(
            measures: s.measures, systemMeasures: [], division: 480,
        )
        #expect(timeline.bps(at: 0) == 2.0)
        #expect(timeline.bps(at: 1000) == 2.0)
    }

    @Test func tempoTimelinePicksUpFromSystemMeasures() {
        // Two measures of a single chord each. A tempo change at
        // the start of the second measure should take effect at
        // tick 480 (one quarter into the score).
        let s = Staff(measures: [
            Measure(voices: [Voice(elements: [chord(60)])]),
            Measure(voices: [Voice(elements: [chord(62)])]),
        ])
        let systemMeasures: [SystemMeasure] = [
            SystemMeasure(),
            SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .tempo(Tempo(beatsPerSecond: 3.0)),
                ),
            ]),
        ]
        let timeline = TempoTimeline.build(
            measures: s.measures,
            systemMeasures: systemMeasures,
            division: 480,
        )
        #expect(timeline.bps(at: 0) == 2.0)
        #expect(timeline.bps(at: 479) == 2.0)
        #expect(timeline.bps(at: 480) == 3.0)
        #expect(timeline.bps(at: 800) == 3.0)
    }

    // MARK: sweep-merge tempo events

    @Test func singleRangeProducesOpenAndClosePair() {
        let ranges = [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (480, microsForBpm(120 / 1.5)),
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (960, microsForBpm(120)),
        ])
    }

    @Test func partialOverlapRedundantBoundaryDropped() {
        // Range A: [0, 720) stretch 2.0
        // Range B: [0, 480) stretch 1.5
        // [0,480) max=2.0; [480,720) max=2.0 (no transition); [720,∞) restore.
        let ranges = [
            FermataRange(startTick: 0, endTick: 720, stretch: 2.0),
            FermataRange(startTick: 0, endTick: 480, stretch: 1.5),
        ]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0, microsForBpm(120 / 2.0)),
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (720, microsForBpm(120)),
        ])
    }

    @Test func partialOverlapWithDifferentEndsEmitsStaircase() {
        // Range A: [0, 480)  stretch 2.0
        // Range B: [240, 720) stretch 1.5
        // [0,240) 2.0; [240,480) 2.0 (no change); [480,720) 1.5; [720,∞) 1.0.
        let ranges = [
            FermataRange(startTick: 0, endTick: 480, stretch: 2.0),
            FermataRange(startTick: 240, endTick: 720, stretch: 1.5),
        ]
        let timeline = TempoTimeline(entries: [(tick: 0, bps: 2.0)])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0, microsForBpm(60)), // 120/2.0
            (480, microsForBpm(80)), // 120/1.5
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (720, microsForBpm(120)),
        ])
    }

    @Test func boundaryTempoChangeDrivesPostFermataValue() {
        // Fermata: [0, 480) stretch 2.0; .tempo(3.0 bps) at tick 480.
        // Open at 0: timeline.bps(at: 0)=2.0 → 60 BPM.
        // Close at 480: timeline.bps(at: 480)=3.0 → 180 BPM.
        let ranges = [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)]
        let timeline = TempoTimeline(entries: [
            (tick: 0, bps: 2.0),
            (tick: 480, bps: 3.0),
        ])
        let result = FermataRanges.tempoEvents(ranges: ranges, timeline: timeline)
        #expect(result.openEvents.map(eventSpec) == [
            (0, microsForBpm(60)),
        ])
        #expect(result.closeEvents.map(eventSpec) == [
            (480, microsForBpm(180)),
        ])
    }

    // MARK: helpers used by sweep-merge tests

    private func eventSpec(_ event: TimedMidiEvent) -> (Int, Int) {
        guard case let .meta(.tempo(micros)) = event.event else {
            Issue.record("expected tempo meta, got \(event.event)")
            return (event.tick, -1)
        }
        return (event.tick, micros)
    }

    private func microsForBpm(_ bpm: Double) -> Int {
        Int((60_000_000.0 / bpm).rounded())
    }
}
