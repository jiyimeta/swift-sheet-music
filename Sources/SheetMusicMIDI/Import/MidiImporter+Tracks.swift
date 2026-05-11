import Foundation
import SheetMusicCore

extension MidiImporter {
    /// MIDI channel index used for GM percussion (0-based).
    static let drumChannel = 9

    /// Pass 2 of the import pipeline: split each SMF track into one or more
    /// `ImportTrack` slices, separating GM channel-10 drum events from
    /// non-drum events. Tracks containing only meta events (e.g. a Format 1
    /// tempo-map track) produce no `ImportTrack`.
    static func partition(_ file: MidiFile) -> [ImportTrack] {
        var output: [ImportTrack] = []
        for (trackIndex, track) in file.tracks.enumerated() {
            let trackName = firstTrackName(in: track)
            let firstProgram = firstProgramChange(in: track)

            let drumEvents = track.events.filter { isOnChannel($0, channel: drumChannel) }
            let pitchedEvents = track.events.filter {
                !isOnChannel($0, channel: drumChannel) && hasNoteContent($0)
            }
            let drumNotes = drumEvents.contains(where: { hasNoteContent($0) })

            if !drumNotes && pitchedEvents.isEmpty {
                continue
            }

            if !pitchedEvents.isEmpty {
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    trackName: trackName,
                    isDrums: false,
                    programChange: firstProgram,
                    events: pitchedEvents + nonChannelEvents(track),
                ))
            }

            if drumNotes {
                let drumName = trackName.map {
                    pitchedEvents.isEmpty ? $0 : "\($0) (drums)"
                }
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    trackName: drumName,
                    isDrums: true,
                    programChange: nil,
                    events: drumEvents,
                ))
            }
        }
        return output
    }

    private static func firstTrackName(in track: MidiTrack) -> String? {
        for ev in track.events {
            if case let .meta(.trackName(name)) = ev.event, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func firstProgramChange(in track: MidiTrack) -> Int? {
        for ev in track.events {
            if case let .programChange(_, program) = ev.event {
                return program
            }
        }
        return nil
    }

    private static func isOnChannel(_ ev: TimedMidiEvent, channel: Int) -> Bool {
        switch ev.event {
        case let .noteOn(c, _, _), let .noteOff(c, _, _),
             let .controlChange(c, _, _), let .programChange(c, _),
             let .pitchBend(c, _):
            return c == channel
        default:
            return false
        }
    }

    private static func hasNoteContent(_ ev: TimedMidiEvent) -> Bool {
        switch ev.event {
        case .noteOn, .noteOff: true
        default: false
        }
    }

    /// Channel-agnostic events (meta, endOfTrack) ride along with
    /// the pitched slice so trackName / endOfTrack survive.
    private static func nonChannelEvents(_ track: MidiTrack) -> [TimedMidiEvent] {
        track.events.filter {
            switch $0.event {
            case .meta, .endOfTrack: true
            default: false
            }
        }
    }
}
