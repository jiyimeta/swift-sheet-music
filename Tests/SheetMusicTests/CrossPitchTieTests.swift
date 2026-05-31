import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Regression tests for a tie whose two endpoints carry *different*
/// sounding pitches. MuseScore produces this shape naturally when a key
/// signature changes mid-tie: the held note keeps its visual staff line
/// but the key change re-spells it, so e.g. C♯ (pitch 73) ties into an
/// invisible C-double-sharp (pitch 74). MuseScore plays such a tie by
/// holding the FIRST note's pitch for the whole span; the tied-into note
/// is never re-attacked.
///
/// Our per-note emit splits a tie into "head emits note-on / tail emits
/// note-off", which silently assumed head and tail share a pitch. Without
/// pitch propagation the head's note-on (73) is never released — a stuck
/// note — and the tail emits a spurious note-off for 74. Reproduces the
/// now_is_the_time.mscz "notes from m101 never turn off" report.
struct CrossPitchTieTests {
    private static func makePart(staff: Staff) -> Part {
        Part(
            id: "P1",
            instrument: Instrument(id: "piano", articulations: []),
            staves: [staff],
        )
    }

    /// Collect note-on/off intervals per pitch and assert every note-on
    /// has a matching note-off (no stuck notes).
    private static func soundingIntervals(
        _ events: [TimedMidiEvent],
    ) -> [Int: [(on: Int, off: Int)]] {
        var open: [Int: [Int]] = [:]
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

    private static func allEvents(_ file: MidiFile) -> [TimedMidiEvent] {
        file.tracks.flatMap(\.events)
    }

    /// C♯5 (73) whole note tied across a key-signature change into an
    /// (invisible) C-double-sharp (74). The held sound must be 73 for the
    /// full two bars; 74 must never sound and must not emit a stray off.
    @Test func crossPitchTie_holdsHeadPitch_noStuckNote() throws {
        let head = 73 // C♯5, tpc 21
        let tail = 74 // C𝄪5, tpc 28 (sounds D, invisible accidental)
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: head, tpc: 21, tieForward: 1)])),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: 5)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: tail, tpc: 28, tieBack: 1)])),
        ])])
        let staff = Staff(measures: [m1, m2])
        let division = 480
        let score = Score(division: division, parts: [Self.makePart(staff: staff)])

        let file = try MidiRenderer.render(score: score)
        let events = Self.allEvents(file)
        let intervals = Self.soundingIntervals(events)

        // The held pitch is 73, sounding from bar 1 start through bar 2 end.
        let headIntervals = intervals[head] ?? []
        #expect(
            headIntervals.count == 1,
            "expected one sounding interval for head pitch \(head), got \(headIntervals.count)",
        )
        if let only = headIntervals.first {
            #expect(only.on == 0)
            // Note-off lands at end-of-span − 1 (the renderer's off
            // convention, `onset + gatedTicks − 1`).
            let expectedOff = 2 * 4 * division - 1
            #expect(
                only.off == expectedOff,
                "tie should hold to end of bar 2 (\(expectedOff)), got \(only.off)",
            )
        }

        // The tied-into pitch 74 must never sound and must not emit a
        // dangling note-off.
        let tailHasOn = events.contains {
            if case let .noteOn(_, p, v) = $0.event { return p == tail && v > 0 }
            return false
        }
        let tailHasOff = events.contains {
            switch $0.event {
            case let .noteOff(_, p, _): return p == tail
            case let .noteOn(_, p, 0): return p == tail
            default: return false
            }
        }
        #expect(!tailHasOn, "tied-into pitch \(tail) must not be struck")
        #expect(!tailHasOff, "tied-into pitch \(tail) must not emit a note-off")
    }

    /// A plain same-pitch tie is untouched: one held note, balanced.
    @Test func samePitchTie_unchanged() throws {
        let pitch = 60
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: pitch, tpc: 14, tieForward: 1)])),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: pitch, tpc: 14, tieBack: 1)])),
        ])])
        let staff = Staff(measures: [m1, m2])
        let division = 480
        let score = Score(division: division, parts: [Self.makePart(staff: staff)])

        let file = try MidiRenderer.render(score: score)
        let intervals = Self.soundingIntervals(Self.allEvents(file))
        let held = intervals[pitch] ?? []
        #expect(held.count == 1)
        if let only = held.first {
            #expect(only.on == 0)
            #expect(only.off == 2 * 4 * division - 1)
        }
    }
}
