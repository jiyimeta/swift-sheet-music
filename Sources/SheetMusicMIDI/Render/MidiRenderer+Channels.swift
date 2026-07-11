import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// GM percussion channel (0-indexed). DAWs like Logic Pro auto-detect any
    /// MIDI events on this channel as drums and load a drum-kit patch.
    static let drumChannel = 9

    /// The 15 assignable melodic channels: all 16 MIDI channels except the
    /// reserved GM drum channel (9). Melodic channel assignment cycles through
    /// these and wraps — MIDI has only 16 channels and every downstream
    /// consumer masks the channel to 4 bits (`ch & 0x0F` in `MidiWriter`, and
    /// the live synth's `MusicDeviceMIDIEvent`), so a channel index that runs
    /// past 15 aliases back down.
    static let melodicChannels: [Int] = (0 ... 15).filter { $0 != drumChannel }

    /// Assign a unique MIDI channel index to each `<Channel>` of every part.
    /// - Explicit `<midiChannel>` is honored.
    /// - Drumset instruments (`<useDrumset>1</useDrumset>`) are auto-routed to
    ///   GM channel 10 (0-indexed: 9). Multiple drumset parts share that
    ///   channel — General MIDI percussion is keyed on note number, not part.
    /// - Other parts are allocated sequentially from a counter, skipping 9 so
    ///   it stays reserved for percussion.
    /// Mirrors MuseScore's `MasterScore::reorderMidiMapping` /
    /// `addMidiMapping` logic in `dom/midimapping.cpp:300`.
    static func assignChannels(score: Score) -> [[ChannelAssignment]] {
        var perPart: [[ChannelAssignment]] = Array(repeating: [], count: score.parts.count)
        // Round-robin over the 15 melodic channels, WRAPPING at the ceiling.
        // MIDI has only 16 channels; an unbounded counter aliases once masked to
        // 4 bits downstream — e.g. the 25th melodic flavour wraps onto wire
        // channel 9 and asks AUMIDISynth for a *melodic* program on its hardwired
        // drum channel, which faults in `SamplerElement::UpdateState`
        // (Crashlytics: `[caulk] CAVerboseAbort` → `HandleProgramChange`). Scores
        // with >15 melodic flavours reuse channels (sharing a program) instead of
        // crashing. MuseScore avoids reuse by spilling to extra MIDI ports; ssm
        // drives a single 16-channel synth, so channel reuse is the graceful
        // bound. Scores within 15 melodic flavours are assigned identically to
        // before (the old counter also skipped 9).
        var nextIndex = 0
        func takeChannel() -> Int {
            let channel = melodicChannels[nextIndex % melodicChannels.count]
            nextIndex += 1
            return channel
        }
        for (partIndex, part) in score.parts.enumerated() {
            let isDrumset = part.instrument.useDrumset
            for flavour in part.instrument.channels {
                let channel: Int
                if let explicit = flavour.midiChannel {
                    channel = explicit
                } else if isDrumset {
                    channel = drumChannel
                } else {
                    channel = takeChannel()
                }
                perPart[partIndex].append(ChannelAssignment(channel: channel, flavour: flavour))
            }
        }
        return perPart
    }

    /// Per-flat-staff MIDI channel, in the same enumeration order as
    /// `Score.allStaves`. Matches the channel each staff's track will
    /// route to in the rendered SMF (see `renderTrack`'s `primaryChannel`).
    /// Multi-staff parts (e.g. piano grand staff) share the same channel
    /// across staves — that's a per-part property, not per-staff.
    ///
    /// Hosts that route every staff onto a single multi-timbral synth
    /// use this to address each staff's notes (program / volume / preview)
    /// on its assigned MIDI channel.
    public static func staffChannels(score: Score) -> [Int] {
        let perPart = assignChannels(score: score)
        var result: [Int] = []
        for (partIndex, part) in score.parts.enumerated() {
            let primary = perPart[partIndex].first?.channel ?? partIndex
            for _ in 0 ..< part.staves.count {
                result.append(primary)
            }
        }
        return result
    }
}
