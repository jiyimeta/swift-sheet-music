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

    /// Assign a MIDI channel to each `<Channel>` of every instrument in
    /// force anywhere in a part — the tick-0 instrument plus **one entry
    /// per change instance**, not per distinct instrument.
    ///
    /// Per-instance is what keeps the exported SMF MuseScore-exact:
    /// three separate "to Piano" changes keep three channels, because
    /// each embeds its own `<Channel>` with its own declared number.
    /// Deduplication belongs to the LIVE playback boundary
    /// (`LiveChannelPlan`) and is emphatically not applied here.
    ///
    /// - Explicit `<midiChannel>` / `<midiPort>` are honored.
    /// - Drumset instruments are auto-routed to GM channel 10 (index 9).
    /// - Everything else is allocated sequentially, skipping 9.
    static func assignChannels(score: Score) -> [[ChannelAssignment]] {
        var perPart: [[ChannelAssignment]] = Array(
            repeating: [], count: score.parts.count,
        )
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
        for partIndex in score.parts.indices {
            let timeline = score.instrumentTimeline(forPart: partIndex)
            for (ordinal, point) in timeline.enumerated() {
                let instrument = point.instrument
                let isDrumset = instrument.useDrumset
                for flavour in instrument.channels {
                    let channel: Int
                    if let explicit = flavour.midiChannel {
                        channel = explicit
                    } else if isDrumset {
                        channel = drumChannel
                    } else {
                        channel = takeChannel()
                    }
                    perPart[partIndex].append(ChannelAssignment(
                        channel: channel,
                        port: flavour.midiPort ?? 0,
                        flavour: flavour,
                        instrumentOrdinal: ordinal,
                    ))
                }
            }
        }
        return perPart
    }

    /// Per-flat-staff MIDI channel, in the same enumeration order as
    /// `Score.allStaves`. Matches the channel each staff's track will
    /// route to in the rendered SMF (see `PartChannelRoute.defaultChannel`).
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
            // `.first` is now the FIRST flavour of the ORDINAL-0
            // (tick-0) instrument, which is what this accessor has
            // always meant. Later ordinals belong to instrument changes.
            let primary = perPart[partIndex]
                .first { $0.instrumentOrdinal == 0 }?.channel ?? partIndex
            for _ in 0 ..< part.staves.count {
                result.append(primary)
            }
        }
        return result
    }
}
