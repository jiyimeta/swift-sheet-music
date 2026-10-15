@testable import SheetMusicMIDI
import Testing

/// MuseScore 4 plays a pedal as CC64 = 127 at the spanner start and 0 at its end, on the part's channel
/// (`framework/audio/engine/internal/synthesizers/fluidsynth/fluidsequencer.cpp:197-210`; values
/// `CTRL_ON` 127 / `CTRL_OFF` 0 at `:35-36`, controller 64 `framework/midi/miditypes.h:46`). Off-before-on at a shared
/// tick and the release at a jump are ssm's own ordering rules: MuseScore plays one spanner per event and has no
/// pedal-change event, so two touching pedals are two spanners (`rg HookType engraving/playback` finds nothing).
@Suite("Sustain pedal events")
struct SustainPedalTests {
    private static func on(_ tick: Int, channel: Int = 0) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: 64, value: 127))
    }

    private static func off(_ tick: Int, channel: Int = 0) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: 64, value: 0))
    }

    // Four 1920-tick bars: bases 0, 1920, 3840, 5760.
    private static let bases = [0, 1920, 3840, 5760]
    private static let spans = [1920, 1920, 1920, 1920]

    /// `order` is the measure order of the unrolled playback; `tickOffset` is the running sum of the spans and
    /// `isIterationStart` is true where the order does not continue (a jump or a loop-back).
    private static func plan(_ order: [Int]) -> [MidiRenderer.PlaybackEntry] {
        var entries: [MidiRenderer.PlaybackEntry] = []
        var tick = 0
        var previous: Int?
        for measure in order {
            entries.append(MidiRenderer.PlaybackEntry(
                measureIndex: measure,
                tickOffset: tick,
                isIterationStart: previous.map { measure != $0 + 1 } ?? false,
            ))
            tick += spans[measure]
            previous = measure
        }
        return entries
    }

    private static func straight() -> [MidiRenderer.PlaybackEntry] {
        plan([0, 1, 2, 3])
    }

    private static func ch(_: Int) -> Int {
        0
    }

    @Test("a pedal is on at its start and off at its end")
    func simple() {
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 480, endTick: 3840)], plan: Self.straight(),
            measureBases: Self.bases, measureSpans: Self.spans, channel: Self.ch,
        )
        #expect(events == [Self.on(480), Self.off(3840)])
    }

    @Test("a pedal ending where the next begins releases first")
    func touchingPedalsReleaseFirst() {
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 0, endTick: 1920), PedalRange(startTick: 1920, endTick: 3840)],
            plan: Self.straight(), measureBases: Self.bases, measureSpans: Self.spans, channel: Self.ch,
        )
        #expect(events == [Self.on(0), Self.off(1920), Self.on(1920), Self.off(3840)])
    }

    @Test("a repeat plays the pedal on both takes")
    func repeatTwice() {
        // bars 0 1 | 0 1 | 2 3 : the second pass starts at unrolled tick 3840.
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 0, endTick: 3840)], plan: Self.plan([0, 1, 0, 1, 2, 3]),
            measureBases: Self.bases, measureSpans: Self.spans, channel: Self.ch,
        )
        #expect(events == [Self.on(0), Self.off(3840), Self.on(3840), Self.off(7680)])
    }

    @Test("a jump out of an open pedal releases it at the jump target")
    func jumpReleasesAnOpenPedal() {
        // Order 0 1 | 0 1 2 3: the pedal 1920..5760 is open when the jump back to bar 0 happens at unrolled 3840.
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 1920, endTick: 5760)], plan: Self.plan([0, 1, 0, 1, 2, 3]),
            measureBases: Self.bases, measureSpans: Self.spans, channel: Self.ch,
        )
        // On at bar 1, released by the jump at 3840, on again at bar 1's second play (5760), and off where bar 2's
        // second play ends the range (7680 + 1920 = 9600).
        #expect(events == [Self.on(1920), Self.off(3840), Self.on(5760), Self.off(9600)])
    }

    @Test("a pedal that never ends is released at the end of the last bar")
    func unterminatedPedalReleasedAtTheEnd() {
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 0, endTick: 100_000)], plan: Self.straight(),
            measureBases: Self.bases, measureSpans: Self.spans, channel: Self.ch,
        )
        #expect(events == [Self.on(0), Self.off(7680)])
    }

    @Test("the channel is the one in force at the start, and the release goes to the same channel")
    func channelFollowsTheStart() {
        let events = SustainPedal.events(
            ranges: [PedalRange(startTick: 0, endTick: 1920)], plan: Self.straight(),
            measureBases: Self.bases, measureSpans: Self.spans, channel: { $0 < 960 ? 3 : 5 },
        )
        #expect(events == [Self.on(0, channel: 3), Self.off(1920, channel: 3)])
    }
}
