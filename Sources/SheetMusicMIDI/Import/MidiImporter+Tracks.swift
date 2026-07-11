import Foundation
import SheetMusicCore

extension MidiImporter {
    /// MIDI channel index used for GM percussion (0-based).
    static let drumChannel = 9

    /// Pass 2 of the import pipeline: split each SMF track into one or more
    /// channel-coherent `ImportTrack` slices. Every distinct *melodic*
    /// MIDI channel present in a track becomes its own pitched slice, and
    /// GM channel-10 drum events are peeled off into a separate slice.
    /// This matters for Format 0 files (and any DAW export that packs
    /// multiple channels into one MTrk): without the per-channel split,
    /// every melodic voice collapses onto a single staff. Tracks
    /// containing only meta events (e.g. a Format 1 tempo-map track)
    /// produce no `ImportTrack`.
    static func partition(_ file: MidiFile) -> [ImportTrack] {
        var output: [ImportTrack] = []
        for (trackIndex, track) in file.tracks.enumerated() {
            let trackName = firstTrackName(in: track)
            // Meta / endOfTrack are channel-agnostic. They ride along with
            // the *first* pitched slice only, so track-level metadata and
            // (notably) lyrics aren't duplicated onto every channel's staff.
            let shared = nonChannelEvents(track)

            let pitchedChannels = noteChannels(in: track)
                .filter { $0 != drumChannel }
            let multiplePitched = pitchedChannels.count > 1

            for (sliceIndex, channel) in pitchedChannels.enumerated() {
                let channelEvents = track.events.filter { isOnChannel($0, channel: channel) }
                let events = sliceIndex == 0 ? channelEvents + shared : channelEvents
                // Keep a lone melodic channel's name untouched (regression-safe);
                // only disambiguate when one track holds several melodic channels.
                let name = multiplePitched
                    ? channelSliceName(trackName: trackName, channel: channel)
                    : trackName
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    channel: channel,
                    trackName: name,
                    isDrums: false,
                    programChange: firstProgramChange(in: track, channel: channel),
                    events: events,
                ))
            }

            let drumEvents = track.events.filter { isOnChannel($0, channel: drumChannel) }
            let drumNotes = drumEvents.contains(where: { hasNoteContent($0) })
            if drumNotes {
                let drumName = trackName.map {
                    pitchedChannels.isEmpty ? $0 : "\($0) (drums)"
                }
                output.append(ImportTrack(
                    trackIndex: trackIndex,
                    channel: drumChannel,
                    trackName: drumName,
                    isDrums: true,
                    programChange: nil,
                    events: drumEvents,
                ))
            }
        }
        return output
    }

    /// Distinct MIDI channels that carry note events, sorted ascending by
    /// channel number so staves appear in the composer's channel order
    /// (ch 1, 2, 3 …) rather than whichever channel happens to enter
    /// first. A channel that only has controller / program-change events
    /// but no notes never becomes a slice.
    private static func noteChannels(in track: MidiTrack) -> [Int] {
        var channels: Set<Int> = []
        for ev in track.events {
            switch ev.event {
            case let .noteOn(c, _, _), let .noteOff(c, _, _):
                channels.insert(c)
            default:
                break
            }
        }
        return channels.sorted()
    }

    /// Distinguishing name for one melodic channel of a multi-channel
    /// track. Reuses the track name when present, else falls back to the
    /// 1-based channel number.
    private static func channelSliceName(trackName: String?, channel: Int) -> String {
        if let name = trackName, !name.isEmpty {
            return "\(name) (ch \(channel + 1))"
        }
        return "Channel \(channel + 1)"
    }

    private static func firstTrackName(in track: MidiTrack) -> String? {
        for ev in track.events {
            if case let .meta(.trackName(name)) = ev.event, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func firstProgramChange(in track: MidiTrack, channel: Int) -> Int? {
        for ev in track.events {
            if case let .programChange(c, program) = ev.event, c == channel {
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
