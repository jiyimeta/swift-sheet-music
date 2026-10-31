import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// `resolveUnisonOverlap` over the tracks of one part at once, for a part with a tie from one of its staves into
    /// another (`DetachedTies`): that note is struck in one track and let go in the other, which one track alone would
    /// read as a note never released and a release of nothing. Events are matched in time order — at one tick a release
    /// before a strike — so a release finds the strike it ends whichever track it is in. Each note stays in the track
    /// whose note-on struck it; every other event stays where it was.
    static func resolveUnisonOverlap(acrossTracks tracks: [[TimedMidiEvent]]) -> [[TimedMidiEvent]] {
        var output = Array(repeating: [TimedMidiEvent](), count: tracks.count)
        var notes: [(track: Int, order: Int, event: TimedMidiEvent)] = []
        for (track, events) in tracks.enumerated() {
            for event in events {
                switch event.event {
                case .noteOn, .noteOff: notes.append((track, notes.count, event))
                default: output[track].append(event)
                }
            }
        }
        notes.sort { lhs, rhs in
            if lhs.event.tick != rhs.event.tick { return lhs.event.tick < rhs.event.tick }
            let lhsRelease = UnisonNote.isRelease(lhs.event.event)
            if lhsRelease != UnisonNote.isRelease(rhs.event.event) { return lhsRelease }
            return lhs.order < rhs.order
        }
        var intervals = UnisonNote.matched(notes.map { ($0.track, $0.event) })
        UnisonNote.resolveOverlaps(&intervals)
        for interval in intervals {
            output[interval.track].append(.noteOn(
                tick: interval.onTick, channel: interval.key.channel, pitch: interval.key.pitch,
                velocity: interval.velocity, cents: interval.cents,
            ))
            output[interval.track].append(TimedMidiEvent(
                tick: interval.offTick,
                event: .noteOff(channel: interval.key.channel, pitch: interval.key.pitch, velocity: 0),
            ))
        }
        return output
    }
}

/// One sounding note of `MidiRenderer.resolveUnisonOverlap(acrossTracks:)`: struck in `track`, from `onTick` to
/// `offTick`.
private struct UnisonNote {
    struct Key: Hashable {
        var channel: Int
        var pitch: Int
    }

    var track: Int
    var key: Key
    var onTick: Int
    var offTick: Int
    var velocity: Int
    var cents: Double

    static func isRelease(_ event: MidiEvent) -> Bool {
        switch event {
        case .noteOff: true
        case let .noteOn(_, _, velocity): velocity == 0
        default: false
        }
    }

    /// Each strike, ended by the first release of its channel and pitch after it — in the order `events` come in. A
    /// release with nothing sounding is dropped; a strike never released ends where it starts.
    static func matched(_ events: [(track: Int, event: TimedMidiEvent)]) -> [UnisonNote] {
        var notes: [UnisonNote] = []
        var pending: [Key: [Int]] = [:]
        for (track, event) in events {
            switch event.event {
            case let .noteOn(channel, pitch, velocity) where velocity > 0:
                let key = Key(channel: channel, pitch: pitch)
                notes.append(UnisonNote(
                    track: track, key: key, onTick: event.tick, offTick: event.tick, velocity: velocity,
                    cents: event.tuningCents,
                ))
                pending[key, default: []].append(notes.count - 1)
            case let .noteOff(channel, pitch, _), let .noteOn(channel, pitch, _):
                let key = Key(channel: channel, pitch: pitch)
                if var ons = pending[key], !ons.isEmpty {
                    notes[ons.removeFirst()].offTick = event.tick
                    pending[key] = ons
                }
            default:
                break
            }
        }
        return notes
    }

    /// The single-track pass's overlap rule: a strike inside a sounding note of its pitch cuts that note off there and
    /// runs on to the later of the two releases.
    static func resolveOverlaps(_ notes: inout [UnisonNote]) {
        var grouped: [Key: [Int]] = [:]
        for (index, note) in notes.enumerated() {
            grouped[note.key, default: []].append(index)
        }
        for indices in grouped.values {
            let sorted = indices.sorted { notes[$0].onTick < notes[$1].onTick }
            for (earlier, later) in zip(sorted, sorted.dropFirst()) {
                let originalOff = notes[earlier].offTick
                if notes[later].onTick < originalOff {
                    notes[earlier].offTick = notes[later].onTick
                    notes[later].offTick = max(notes[later].offTick, originalOff)
                }
            }
        }
    }
}
