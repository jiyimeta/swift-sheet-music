import CFluidSynth
import Foundation
import SheetMusicAudioCore

// The FluidSynth objects the Windows engine drives: one synth + player pair for the score and one for the metronome,
// the shape Android's `FluidSynthEngine` + `PlayerDriver` and `MetronomeMixer` have. These are thin value wrappers
// over the C handles; who may call what, and when, is the engine's business (see `PlaybackCore`).

/// A `fluid_synth_t` with the settings it was made from, and the SoundFont loaded into it.
///
/// A value on purpose: nothing deletes it behind the engine's back. The engine deletes it explicitly
/// (`delete()`), after the players attached to it and only once nothing renders it any more.
struct SynthHandle: @unchecked Sendable {
    let settings: OpaquePointer
    let synth: OpaquePointer
    /// FluidSynth's id for the loaded SoundFont, or `-1` when none is (no URL, or FluidSynth refused the file). A
    /// synth without one plays nothing, as the Apple and Android engines do; `diagnostics` says which it is.
    let soundFontID: Int32
    /// The SoundFont this synth was asked to load, so a later prepare can tell whether it can keep the synth.
    let soundFontURL: URL?
    let sampleRate: Double

    /// FluidSynth's own default gain (0.2) is far quieter than the other engines; 2.0 is Android's
    /// (`sheetmusicaudio_jni.cpp`, chosen by ear against AUMIDISynth).
    static let gain: Float = 2.0

    /// Builds a synth at `sampleRate` and loads `soundFontURL` into it. Slow with a large General MIDI SoundFont —
    /// `sfload` reads every sample — so the engine calls it outside its lock.
    ///
    /// - Throws: `WindowsAudioError.synth` when FluidSynth cannot make the settings or the synth. A SoundFont it
    ///   cannot load is not an error (see `soundFontID`).
    static func make(sampleRate: Double, soundFontURL: URL?) throws -> SynthHandle {
        guard let settings = new_fluid_settings() else { throw WindowsAudioError.synth("new_fluid_settings failed") }
        fluid_settings_setnum(settings, "synth.sample-rate", sampleRate)
        // Control calls (CC, program, note on/off) reach the synth from the engine's control thread while the render
        // thread writes audio; FluidSynth serializes them on its own mutex.
        fluid_settings_setint(settings, "synth.threadsafe-api", 1)
        // The player advances inside `fluid_synth_write_float`, by the frames rendered, instead of on a system timer:
        // its tick is then exactly the audio written, and a render that pauses (no device) pauses the music with it.
        fluid_settings_setstr(settings, "player.timing-source", "sample")
        // No GM system reset when a player takes up a sequence: the engine's `reassertChannelState` is the only
        // authority on bank, program, CC 2 / 7 and tuning, as `applyMixerState` is on the Apple engine.
        fluid_settings_setint(settings, "player.reset-synth", 0)
        // Every sample in memory at load, never streamed from the file mid-playback.
        fluid_settings_setint(settings, "synth.dynamic-sample-loading", 0)
        guard let synth = new_fluid_synth(settings) else {
            delete_fluid_settings(settings)
            throw WindowsAudioError.synth("new_fluid_synth failed")
        }
        fluid_synth_set_gain(synth, gain)
        var soundFontID: Int32 = -1
        if let soundFontURL {
            // UTF-8, which FluidSynth's Windows file layer widens itself.
            soundFontID = soundFontURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return fluid_synth_sfload(synth, path, 1)
            }
        }
        return SynthHandle(
            settings: settings, synth: synth, soundFontID: max(-1, soundFontID), soundFontURL: soundFontURL,
            sampleRate: sampleRate,
        )
    }

    /// Frees the synth and its settings. Only once every player on it is deleted and nothing renders it.
    func delete() {
        delete_fluid_synth(synth)
        delete_fluid_settings(settings)
    }

    /// Renders `frames` frames into `out`, interleaved stereo, overwriting what is there.
    @inline(__always)
    func write(frames: Int32, into out: UnsafeMutablePointer<Float>) {
        fluid_synth_write_float(synth, frames, out, 0, 2, out, 1, 2)
    }

    func controlChange(channel: Int32, controller: Int32, value: Int32) {
        fluid_synth_cc(synth, channel, controller, value)
    }

    /// Sends `messages` to `channel` in order — a tuning RPN burst (`MasterTuning.rpnControlChanges`). Allocates
    /// nothing.
    func send(_ messages: [MasterTuning.CC], onChannel channel: Int32) {
        for message in messages {
            fluid_synth_cc(synth, channel, Int32(message.controller), Int32(message.value))
        }
    }

    func noteOn(channel: Int32, pitch: Int32, velocity: Int32) {
        fluid_synth_noteon(synth, channel, pitch, velocity)
    }

    func noteOff(channel: Int32, pitch: Int32) {
        fluid_synth_noteoff(synth, channel, pitch)
    }

    /// Note-off on every sounding note of `channel` (`-1`: every channel); releases ring out.
    func allNotesOff(channel: Int32 = -1) {
        fluid_synth_all_notes_off(synth, channel)
    }

    /// Silences `channel` (`-1`: every channel) at once, releases included — MIDI's All Sound Off.
    func allSoundsOff(channel: Int32 = -1) {
        fluid_synth_all_sounds_off(synth, channel)
    }

    /// Selects `program` in `bank` of the loaded SoundFont on `channel`. `false` when there is no SoundFont or it has
    /// no such preset (the channel then keeps what it had, as on Android).
    @discardableResult
    func selectProgram(channel: Int32, bank: Int32, program: Int32) -> Bool {
        guard soundFontID >= 0 else { return false }
        return fluid_synth_program_select(synth, channel, soundFontID, bank, program) == FLUID_OK
    }

    func setDrumChannel(_ channel: Int32, isDrum: Bool) {
        let type = isDrum ? CHANNEL_TYPE_DRUM : CHANNEL_TYPE_MELODIC
        fluid_synth_set_channel_type(synth, channel, Int32(type.rawValue))
    }

    /// Back to the state of a new synth: voices off, every channel's controllers, programs and types reset.
    func systemReset() {
        fluid_synth_system_reset(synth)
    }

    // MARK: Read-backs (probe)

    func controller(_ controller: Int32, onChannel channel: Int32) -> Int? {
        var value: Int32 = 0
        guard fluid_synth_get_cc(synth, channel, controller, &value) == FLUID_OK else { return nil }
        return Int(value)
    }

    func program(onChannel channel: Int32) -> (bank: Int, program: Int)? {
        var soundFont: Int32 = 0
        var bank: Int32 = 0
        var preset: Int32 = 0
        guard fluid_synth_get_program(synth, channel, &soundFont, &bank, &preset) == FLUID_OK else { return nil }
        return (Int(bank), Int(preset))
    }

    var activeVoiceCount: Int {
        Int(fluid_synth_get_active_voice_count(synth))
    }

    /// The channel's coarse (semitones) and fine (cents) tuning, as the tuning RPN left FluidSynth's generators.
    func tuning(onChannel channel: Int32) -> (coarse: Double, fine: Double) {
        let coarse = fluid_synth_get_gen(synth, channel, Int32(GEN_COARSETUNE.rawValue))
        let fine = fluid_synth_get_gen(synth, channel, Int32(GEN_FINETUNE.rawValue))
        return (Double(coarse), Double(fine))
    }

    func integerSetting(_ name: String) -> Int? {
        var value: Int32 = 0
        guard fluid_settings_getint(settings, name, &value) == FLUID_OK else { return nil }
        return Int(value)
    }
}

/// A `fluid_player_t` over one SMF, attached to one synth.
///
/// With `player.timing-source = sample` the player moves only inside its synth's `fluid_synth_write_float`, once per
/// 64-frame block (`FLUID_BUFSIZE`), at the start of the block. A seek is a request the next played block carries out
/// — until then `tick` still reports the old position, which is why the engine keeps its own `pendingScoreTick`.
///
/// What FluidSynth 2.x does here, read from `fluid_midi.c` (checked against 2.4.4):
/// - the SMF is parsed in the first block the player plays, not by `fluid_player_add_mem`;
/// - `fluid_player_seek` on a player that is not READY refuses a tick past the length of the sequence as parsed so
///   far — so a player stopped before it ever played refuses every seek past tick 0 (`stop` and
///   `Shared.stopPlayers` keep that from happening);
/// - `fluid_player_stop` marks the player DONE and seeks it to its current tick; its next block sends All Sound Off
///   to every channel it played on;
/// - a seek is carried out with a chase — every event up to the target but note on / off, tempo included — after All
///   Sound Off on the channels the player had played on.
struct PlayerHandle: @unchecked Sendable {
    let player: OpaquePointer

    /// A player on `synth` holding `midi`, at tempo scale `rate`.
    ///
    /// Must not run while `synth` renders: `new_fluid_player` registers the player's sample timer on the synth, and
    /// FluidSynth does that without the synth's own lock (`new_fluid_sample_timer`), so it would race the timer walk
    /// inside `fluid_synth_write_float`. The engine calls it under its lock, or on a synth not yet rendered.
    static func make(on synth: SynthHandle, midi: Data, rate: Float) throws -> PlayerHandle {
        guard let player = new_fluid_player(synth.synth) else {
            throw WindowsAudioError.synth("new_fluid_player failed")
        }
        let added = midi.withUnsafeBytes { buffer in
            fluid_player_add_mem(player, buffer.baseAddress, buffer.count)
        }
        guard added == FLUID_OK else {
            delete_fluid_player(player)
            throw WindowsAudioError.synth("the player refused the MIDI")
        }
        let handle = PlayerHandle(player: player)
        handle.setTempo(rate)
        return handle
    }

    /// Frees the player. Under the same rule as `make`: `delete_fluid_player` unregisters its sample timer without the
    /// synth's lock.
    func delete() {
        delete_fluid_player(player)
    }

    func play() {
        fluid_player_play(player)
    }

    /// Stops a playing player; one that is not playing is left alone. A READY player (never played) in particular
    /// has to stay READY: stopped, it would refuse every seek past tick 0 until it had played (see the type's notes).
    func stop() {
        guard isPlaying else { return }
        fluid_player_stop(player)
    }

    /// Asks the player to jump to `tick` — carried out, with the controller chase, by the next played block. While
    /// playing, FluidSynth refuses a second request until the first is carried out, so the engine issues at most one
    /// per block (`Shared.deferredSeek`). A target past the end of a parsed sequence lands on its end.
    @discardableResult
    func seek(to tick: Int) -> Bool {
        let target = Int32(clamping: max(0, tick))
        if fluid_player_seek(player, target) == FLUID_OK {
            return true
        }
        // Past the end of a parsed sequence, which FluidSynth refuses unless the player is READY: its end instead. (The
        // length is only asked for here: FluidSynth walks every event of every track to answer.)
        let length = totalTicks
        guard length > 0, Int(target) > length else { return false }
        return fluid_player_seek(player, Int32(clamping: length)) == FLUID_OK
    }

    var tick: Int {
        Int(fluid_player_get_current_tick(player))
    }

    /// The parsed sequence's length; 0 until the player has played a block (FluidSynth parses the SMF then). Costs a
    /// walk over every event.
    var totalTicks: Int {
        Int(fluid_player_get_total_ticks(player))
    }

    var isPlaying: Bool {
        fluid_player_get_status(player) == Int32(FLUID_PLAYER_PLAYING.rawValue)
    }

    /// Whether the player is done: stopped, or run out of events (FluidSynth keeps a finished player PLAYING while
    /// its voices ring out, plus two seconds).
    var isDone: Bool {
        fluid_player_get_status(player) == Int32(FLUID_PLAYER_DONE.rawValue)
    }

    /// Scales the sequence's own tempo map by `rate` (`FLUID_PLAYER_TEMPO_INTERNAL`), as `AVAudioSequencer.rate` and
    /// Android's `PlayerDriver.setTempo` do. FluidSynth accepts 0.001…1000 and ignores anything else.
    func setTempo(_ rate: Float) {
        fluid_player_set_tempo(player, Int32(FLUID_PLAYER_TEMPO_INTERNAL.rawValue), Double(rate))
    }
}
