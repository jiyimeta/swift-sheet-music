import Foundation
import SheetMusicCore

/// Renders a `Score` into a `MidiFile`. The implementation is split across
/// `MidiRenderer+*.swift` extensions for: header emission, channel allocation,
/// per-voice walking (with arpeggio), repeat-list expansion, MeasureRepeat
/// resolution, and the unison-overlap merge step.
public enum MidiRenderer {
    /// Default base velocity for "mf" when no Dynamic has been seen.
    static let defaultDynamicVelocity = 80

    /// Default tempo if the score has no Tempo markers (120 BPM = 500000 µs/quarter).
    static let defaultMicrosPerQuarter = 500_000

    /// Render the given `Score` into a `MidiFile` ready for serialisation.
    public static func render(score: Score) throws -> MidiFile {
        var tracks: [MidiTrack] = []
        let channelAssignments = assignChannels(score: score)
        var trackIndex = 0
        for (partIndex, part) in score.parts.enumerated() {
            let channels = channelAssignments[partIndex]
            let primaryChannel = channels.first?.channel ?? partIndex
            let port = part.instrument.channel.midiPort ?? 0
            for (s, staff) in part.staves.enumerated() {
                let track = renderTrack(
                    staff: staff,
                    part: part,
                    primaryChannel: primaryChannel,
                    channels: channels,
                    port: port,
                    isFirstTrack: trackIndex == 0,
                    isTopOfPart: s == 0,
                    division: score.division
                )
                tracks.append(track)
                trackIndex += 1
            }
        }
        return MidiFile(division: score.division, format: 1, tracks: tracks)
    }

    /// One MIDI channel allocated to a particular `<Channel>` flavour of a part.
    struct ChannelAssignment {
        var channel: Int
        var flavour: InstrumentChannel
    }

    private static func renderTrack(
        staff: Staff,
        part: Part,
        primaryChannel: Int,
        channels: [ChannelAssignment],
        port: Int,
        isFirstTrack: Bool,
        isTopOfPart: Bool,
        division: Int
    ) -> MidiTrack {
        var events: [TimedMidiEvent] = headerEvents(
            staff: staff,
            part: part,
            channels: channels,
            port: port,
            isFirstTrack: isFirstTrack,
            isTopOfPart: isTopOfPart
        )

        var voiceEventBuckets: [[TimedMidiEvent]] = []
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            let (voiceEvents, _) = renderVoice(
                voiceIndex: voiceIndex,
                staff: staff,
                part: part,
                channel: primaryChannel,
                division: division
            )
            voiceEventBuckets.append(voiceEvents)
        }
        // Multi-voice merge resolves same-pitch overlaps (the "muted unison" case).
        let merged = resolveUnisonOverlap(voiceEventBuckets.flatMap { $0 })
        events.append(contentsOf: merged)

        // EoT lands one tick after the last produced event (MuseScore convention):
        // for note-bearing tracks this is final-noteOff + 1; for empty tracks it's 1.
        let lastEventTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastEventTick + 1, event: .endOfTrack))

        // Stable sort by tick — preserves header insertion order at tick 0
        // and keeps voice-0 events ahead of voice-1 events at the same tick.
        let sorted = events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)

        return MidiTrack(events: sorted)
    }
}
