import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Regression tests for ties crossing a tremolo chord. A note tied into a
/// tremolo (`tieBack`) must not re-attack on the first stroke, and one tied
/// out (`tieForward`) must not release on the last stroke. Otherwise the
/// note-on/off counts go unbalanced and `resolveUnisonOverlap`'s FIFO
/// pairing stretches a later same-pitch note across a rest gap into a
/// stuck note (observed as the m2 whole note "never turning off").
struct TremoloTieTests {
    private static func makePart(staff: Staff) -> Part {
        Part(
            id: "P1",
            instrument: Instrument(id: "piano", articulations: []),
            staves: [staff],
        )
    }

    /// Asserts every note-on on a (channel, pitch) has a matching note-off
    /// and returns the resolved sounding intervals per pitch.
    private static func soundingIntervals(
        _ events: [TimedMidiEvent],
    ) -> [Int: [(on: Int, off: Int)]] {
        var open: [Int: [Int]] = [:] // pitch -> stack of on-ticks
        var out: [Int: [(on: Int, off: Int)]] = [:]
        for ev in events {
            switch ev.event {
            case let .noteOn(_, pitch, vel) where vel > 0:
                open[pitch, default: []].append(ev.tick)
            case let .noteOff(_, pitch, _), let .noteOn(_, pitch, 0):
                if var stack = open[pitch], let onTick = stack.first {
                    stack.removeFirst()
                    open[pitch] = stack
                    out[pitch, default: []].append((onTick, ev.tick))
                }
            default:
                break
            }
        }
        for (pitch, stack) in open {
            #expect(stack.isEmpty, "pitch \(pitch) has \(stack.count) unmatched note-on(s)")
        }
        return out
    }

    /// m1 eighth (tieForward) → m2 whole + r16 tremolo (tieBack) →
    /// m3 quarter (same pitch). Before the fix, m3's note stretched to
    /// the next same-pitch onset many measures later.
    @Test func tieIntoTremoloThenSamePitch_doesNotStick() throws {
        let pitch = 72
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: pitch, tpc: 14, tieForward: 1)],
            )),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(
                duration: .whole,
                notes: [Note(pitch: pitch, tpc: 14, tieBack: 1)],
                tremolo: Tremolo(subtype: .r16),
            )),
        ])])
        let m3 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)])),
        ])])
        let staff = Staff(measures: [m1, m2, m3])
        let division = 480
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: division,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: division),
        )
        let intervals = Self.soundingIntervals(events)[pitch] ?? []
        // The last sounding interval is m3's quarter note. It must end at
        // its own boundary (m3 start + quarter), not bleed onward.
        let m3Start = 2 * 4 * division // two 4/4 measures of 1920 ticks
        guard let last = intervals.max(by: { $0.off < $1.off }) else {
            Issue.record("no pitch-\(pitch) intervals emitted")
            return
        }
        #expect(
            last.off <= m3Start + division,
            "m3 quarter note runs to \(last.off); expected ≤ \(m3Start + division)",
        )
    }

    /// A tie OUT of a tremolo (tremolo note's note tieForward) must not
    /// release on the last stroke — it flows into the following chord.
    @Test func tieOutOfTremolo_suppressesLastStrokeOff() throws {
        let pitch = 60
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(
                duration: .whole,
                notes: [Note(pitch: pitch, tpc: 14, tieForward: 1)],
                tremolo: Tremolo(subtype: .r16),
            )),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14, tieBack: 1)])),
        ])])
        let staff = Staff(measures: [m1, m2])
        let division = 480
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: division,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: division),
        )
        let intervals = Self.soundingIntervals(events)[pitch] ?? []
        // The last tremolo stroke's note-off is suppressed, so the final
        // sounding interval flows past the tremolo region (measure 1, the
        // whole note = 4 * division ticks) into the tied quarter in
        // measure 2. Without the fix it would release at the last stroke
        // boundary inside measure 1 (and leave an unmatched note-off).
        let tremoloRegionEnd = 4 * division // whole note, one 4/4 bar
        guard let last = intervals.max(by: { $0.off < $1.off }) else {
            Issue.record("no pitch-\(pitch) intervals emitted")
            return
        }
        #expect(
            last.off >= tremoloRegionEnd,
            "tied-out note released early at \(last.off); expected it to flow into measure 2 (≥ \(tremoloRegionEnd))",
        )
    }
}
