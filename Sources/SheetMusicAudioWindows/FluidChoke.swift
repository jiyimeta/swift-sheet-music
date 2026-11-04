import CFluidSynth
import Foundation
import SheetMusicMIDI

/// The cymbal choke on FluidSynth: what SwiftySynth's `Synthesizer.choke(key:on:)` does on the Apple and Android
/// engines, for the marker the playback render puts at the end of a choked note (`ChokeMarker`, CC 110 whose value is
/// the key). FluidSynth ignores the undefined controller, and a note-off alone does not stop a cymbal — the crash in
/// GeneralUser-GS releases over 48.5 s — so every sounding voice at that channel and key has its volume-envelope
/// release cut to `releaseSeconds` first, then the note is released: it fades from the level it is at.
///
/// A held sustain pedal still holds the note here, where SwiftySynth's choke ignores it; a drum channel rarely has one.
enum FluidChoke {
    /// SwiftySynth's `Synthesizer.chokeReleaseTime`.
    static let releaseSeconds = 0.05

    /// The release in the SoundFont unit the generator takes: timecents, 1200 × log2(seconds).
    static var releaseTimecents: Float {
        Float(1200 * log2(releaseSeconds))
    }

    /// The most voices one choke looks at: FluidSynth's default polyphony.
    private static let voiceCapacity = 256

    /// The player's event handler: the choke marker chokes, every other event goes to the synth as FluidSynth's own
    /// handler would send it. `data` is the synth.
    static let playbackHandler: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?) -> Int32 = { data, event in
        guard let data, let event else { return FLUID_FAILED }
        if fluid_midi_event_get_type(event) == 0xB0,
           fluid_midi_event_get_control(event) == Int32(ChokeMarker.controller)
        {
            choke(
                synth: OpaquePointer(data), channel: fluid_midi_event_get_channel(event),
                key: fluid_midi_event_get_value(event),
            )
            return FLUID_OK
        }
        return fluid_synth_handle_midi_event(data, event)
    }

    /// Fades every voice sounding `key` on `channel` within `releaseSeconds`. Runs on the render thread, inside the
    /// synth's own block, as every event the player sends does.
    static func choke(synth: OpaquePointer, channel: Int32, key: Int32) {
        var voices = [OpaquePointer?](repeating: nil, count: voiceCapacity)
        voices.withUnsafeMutableBufferPointer { buffer in
            fluid_synth_get_voicelist(synth, buffer.baseAddress, Int32(buffer.count), -1)
        }
        let release = Int32(GEN_VOLENVRELEASE.rawValue)
        for case let voice? in voices
            where fluid_voice_is_playing(voice) != 0
            && fluid_voice_get_channel(voice) == channel && fluid_voice_get_key(voice) == key
        {
            fluid_voice_gen_set(voice, release, releaseTimecents)
            fluid_voice_update_param(voice, release)
        }
        fluid_synth_noteoff(synth, channel, key)
    }
}
