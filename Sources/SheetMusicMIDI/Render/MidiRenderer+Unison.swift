import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Merge per-voice note events into a single stream, resolving same-channel /
    /// same-pitch overlaps the way MuseScore does:
    ///   - Sort same-pitch note intervals by on-tick.
    ///   - When interval B overlaps a still-active interval A (A.on ≤ B.on < A.off):
    ///       * truncate A's noteOff to B.on
    ///       * extend B's noteOff to max(B.off, A's original off)
    ///   - Notes on different (channel, pitch) keys are independent.
    /// Non-note events (controlChange/programChange/meta/endOfTrack) pass through.
    static func resolveUnisonOverlap(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        struct Interval {
            var onTick: Int
            var offTick: Int
            var channel: Int
            var pitch: Int
            var velocity: Int
        }

        var intervals: [Interval] = []
        var passthrough: [TimedMidiEvent] = []
        var pendingOns: [String: [Int]] = [:] // key "ch|pitch" -> [interval indices]
        func key(_ ch: Int, _ p: Int) -> String {
            "\(ch)|\(p)"
        }

        for ev in events {
            switch ev.event {
            case let .noteOn(ch, pitch, vel) where vel > 0:
                let interval = Interval(
                    onTick: ev.tick, offTick: ev.tick,
                    channel: ch, pitch: pitch, velocity: vel,
                )
                intervals.append(interval)
                pendingOns[key(ch, pitch), default: []].append(intervals.count - 1)
            case let .noteOff(ch, pitch, _),
                 let .noteOn(ch, pitch, 0):
                if var ons = pendingOns[key(ch, pitch)], !ons.isEmpty {
                    let idx = ons.removeFirst()
                    pendingOns[key(ch, pitch)] = ons
                    intervals[idx].offTick = ev.tick
                }
            default:
                passthrough.append(ev)
            }
        }

        // Resolve overlaps per (ch, pitch).
        var grouped: [String: [Int]] = [:]
        for (i, iv) in intervals.enumerated() {
            grouped[key(iv.channel, iv.pitch), default: []].append(i)
        }
        for indices in grouped.values {
            let sorted = indices.sorted { intervals[$0].onTick < intervals[$1].onTick }
            for k in 0 ..< (sorted.count - 1) {
                let aIdx = sorted[k]
                let bIdx = sorted[k + 1]
                let aOriginalOff = intervals[aIdx].offTick
                let bOn = intervals[bIdx].onTick
                if bOn < aOriginalOff {
                    intervals[aIdx].offTick = bOn
                    intervals[bIdx].offTick = max(intervals[bIdx].offTick, aOriginalOff)
                }
            }
        }

        var output: [TimedMidiEvent] = passthrough
        for iv in intervals {
            let on = MidiEvent.noteOn(channel: iv.channel, pitch: iv.pitch, velocity: iv.velocity)
            let off = MidiEvent.noteOff(channel: iv.channel, pitch: iv.pitch, velocity: 0)
            output.append(TimedMidiEvent(tick: iv.onTick, event: on))
            output.append(TimedMidiEvent(tick: iv.offTick, event: off))
        }
        return output
    }
}
