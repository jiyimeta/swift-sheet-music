import CFluidSynth
import Foundation
import SheetMusicCore
import SheetMusicMIDI

/// One FluidSynth synth and the MIDI player on it — what Android's `FluidSynthEngine` and `PlayerDriver` are together.
///
/// The SMF from `AudioMidiBridge.renderMidi` arrives with its channels already on the live channel plan, so one synth
/// plays the whole score. `renderMidi` strips each mixer-owned channel's tick-0 program and CC 7 so that the engine is
/// their only authority; `configure` is where the engine asserts them.
///
/// Built with `synth.threadsafe-api = 1`, so the render thread and the control calls may interleave.
final class FluidSynthRenderer: @unchecked Sendable {
    private let settings: OpaquePointer
    private let synth: OpaquePointer
    private let soundFontID: Int32
    private var player: OpaquePointer?

    /// FluidSynth's `player.reset-synth` stays at its default (on), as on Android: the programs `configure` sets
    /// survive the player taking up the sequence (measured with FluidSynth 2.6.1 on Windows, 2026-09-30).
    init(sampleRate: Double, soundFontPath: String) throws {
        guard let settings = new_fluid_settings() else { throw WindowsAudioError.synth("new_fluid_settings failed") }
        fluid_settings_setnum(settings, "synth.sample-rate", sampleRate)
        fluid_settings_setint(settings, "synth.threadsafe-api", 1)
        // The player advances by the frames rendered rather than by a system timer, so its position is exactly the
        // audio written, and a paused stream pauses the sequence with it.
        fluid_settings_setstr(settings, "player.timing-source", "sample")
        guard let synth = new_fluid_synth(settings) else {
            delete_fluid_settings(settings)
            throw WindowsAudioError.synth("new_fluid_synth failed")
        }
        // Android's gain (sheetmusicaudio_jni.cpp).
        fluid_synth_set_gain(synth, 2.0)
        let soundFontID = fluid_synth_sfload(synth, soundFontPath, 1)
        guard soundFontID >= 0 else {
            delete_fluid_synth(synth)
            delete_fluid_settings(settings)
            throw WindowsAudioError.synth("cannot load the SoundFont at \(soundFontPath)")
        }
        self.settings = settings
        self.synth = synth
        self.soundFontID = soundFontID
    }

    deinit {
        unload()
        delete_fluid_synth(synth)
        delete_fluid_settings(settings)
    }

    /// Android's `FluidSynthEngine.setupStaves`, per strip of the plan: drum channels get drum semantics and bank 128,
    /// every channel its program, melodic channels CC 2 fully open (MuseScore's expressive banks gate their volume on
    /// the breath controller, and nothing here streams it), and CC 7 the score's own channel volume.
    func configure(_ plan: LiveChannelPlan) {
        for strip in plan.strips {
            let channel = Int32(strip.liveChannel)
            let isDrums = strip.instrument.useDrumset
            if isDrums {
                fluid_synth_set_channel_type(synth, channel, Int32(CHANNEL_TYPE_DRUM.rawValue))
            }
            let bank = isDrums ? 128 : strip.instrument.channel.bank
            let program = min(max(strip.instrument.channel.program, 0), 127)
            fluid_synth_program_select(synth, channel, soundFontID, Int32(clamping: bank), Int32(program))
            if !isDrums {
                fluid_synth_cc(synth, channel, 2, 127)
            }
            fluid_synth_cc(synth, channel, 7, Int32(min(max(strip.instrument.channel.volume, 0), 127)))
        }
    }

    /// The program a channel is on now, or `nil` when FluidSynth cannot say — for checking that `configure` held.
    func program(onChannel channel: Int) -> Int? {
        var soundFont: Int32 = 0
        var bank: Int32 = 0
        var preset: Int32 = 0
        guard fluid_synth_get_program(synth, Int32(channel), &soundFont, &bank, &preset) == FLUID_OK else { return nil }
        return Int(preset)
    }

    func load(midi: Data) throws {
        unload()
        guard let player = new_fluid_player(synth) else { throw WindowsAudioError.synth("new_fluid_player failed") }
        let added = midi.withUnsafeBytes { buffer in
            fluid_player_add_mem(player, buffer.baseAddress, buffer.count)
        }
        guard added == FLUID_OK else {
            delete_fluid_player(player)
            throw WindowsAudioError.synth("the player refused the MIDI")
        }
        self.player = player
    }

    func play() {
        if let player {
            fluid_player_play(player)
        }
    }

    /// Renders `frames` frames of interleaved stereo into `buffer`. Called on the render thread only.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        fluid_synth_write_float(synth, Int32(frames), buffer, 0, 2, buffer, 1, 2)
    }

    func allNotesOff() {
        fluid_synth_all_notes_off(synth, -1)
    }

    private func unload() {
        guard let player else { return }
        fluid_player_stop(player)
        delete_fluid_player(player)
        self.player = nil
    }
}
