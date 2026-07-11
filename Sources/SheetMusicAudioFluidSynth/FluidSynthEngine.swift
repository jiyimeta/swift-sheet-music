import CFluidSynth
import Foundation

/// Thin Swift wrapper over libfluidsynth: owns one `fluid_synth_t` (+ an
/// optional `fluid_player_t`) and exposes safe Swift calls for SoundFont
/// loading, live note/CC/program control, block rendering, and SMF-driven
/// transport.
///
/// Mirrors the Android JNI bridge (`sheetmusicaudio_jni.cpp`) 1:1 so the two
/// platforms share behavior — same settings (`synth.sample-rate`,
/// `synth.threadsafe-api = 1`), same gain (2.0), same default polyphony (256),
/// same player transport.
///
/// FluidSynth's public API is internally synchronized (`synth.threadsafe-api`),
/// so transport calls from the main actor and `render(...)` from the audio
/// render thread are safe to interleave. Hence `@unchecked Sendable`.
public final class FluidSynthEngine: @unchecked Sendable {
    private let settings: OpaquePointer
    private let synth: OpaquePointer
    private var player: OpaquePointer?
    /// `sfid` of the currently-loaded SoundFont, so a reload can unload it.
    private var loadedSFID: Int32 = -1

    public init(sampleRate: Double) {
        settings = new_fluid_settings()
        fluid_settings_setnum(settings, "synth.sample-rate", sampleRate)
        // Allow calls from the render thread and the main actor concurrently.
        fluid_settings_setint(settings, "synth.threadsafe-api", 1)
        synth = new_fluid_synth(settings)
        // Default FluidSynth gain (0.2) is very quiet; ~2.0 matches the
        // perceived loudness of the AUMIDISynth path. Android uses the same.
        fluid_synth_set_gain(synth, 2.0)
    }

    deinit {
        if let player {
            fluid_player_stop(player)
            delete_fluid_player(player)
        }
        delete_fluid_synth(synth)
        delete_fluid_settings(settings)
    }

    // MARK: SoundFont

    /// Load (or reload) the full-GM SoundFont at `path`, unloading any prior
    /// one. Returns the new `sfid` (>= 0) or a negative value on failure.
    @discardableResult
    public func loadSoundFont(_ path: String) -> Int32 {
        if loadedSFID >= 0 {
            fluid_synth_sfunload(synth, loadedSFID, 1)
            loadedSFID = -1
        }
        let sfid = fluid_synth_sfload(synth, path, 1)
        if sfid >= 0 { loadedSFID = sfid }
        return sfid
    }

    /// Currently-loaded SoundFont id, or -1 when none is loaded.
    public var currentSFID: Int32 {
        loadedSFID
    }

    public func programSelect(
        channel: UInt8, bank: UInt8, program: UInt8,
    ) {
        guard loadedSFID >= 0 else { return }
        fluid_synth_program_select(
            synth, Int32(channel), loadedSFID,
            Int32(bank), Int32(program),
        )
    }

    /// Mark a channel melodic or drum. FluidSynth resolves percussion via the
    /// channel type (not a bank byte); the score's drum staves map to their
    /// renderer-assigned channel(s) here.
    public func setChannelType(channel: UInt8, isDrum: Bool) {
        // fluid_midi_channel_type: 0 = CHANNEL_TYPE_MELODIC, 1 = CHANNEL_TYPE_DRUM
        // (matching the Android JNI, which passes the raw int).
        fluid_synth_set_channel_type(synth, Int32(channel), isDrum ? 1 : 0)
    }

    // MARK: Live control

    public func noteOn(channel: UInt8, key: UInt8, velocity: UInt8) {
        fluid_synth_noteon(synth, Int32(channel), Int32(key), Int32(velocity))
    }

    public func noteOff(channel: UInt8, key: UInt8) {
        fluid_synth_noteoff(synth, Int32(channel), Int32(key))
    }

    public func controlChange(channel: UInt8, controller: UInt8, value: UInt8) {
        fluid_synth_cc(synth, Int32(channel), Int32(controller), Int32(value))
    }

    /// Live sounding-voice count — the FluidSynth analogue of AUMIDISynth's
    /// read-only property 4104. Used to assert the voice pool is never pinned.
    public var activeVoiceCount: Int {
        Int(fluid_synth_get_active_voice_count(synth))
    }

    // MARK: Rendering

    /// Render `frameCount` frames into two non-interleaved float32 buffers.
    /// Called from the audio render thread. Advances the player clock (when a
    /// player is loaded and playing) as a side effect of synthesis.
    public func render(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
    ) {
        fluid_synth_write_float(
            synth, Int32(frameCount),
            UnsafeMutableRawPointer(left), 0, 1,
            UnsafeMutableRawPointer(right), 0, 1,
        )
    }

    // MARK: Player transport (SMF-driven full playback)

    /// Load a Standard MIDI File (in memory) into a fresh player, replacing any
    /// previous one. `add_mem` copies the bytes, so the buffer need not outlive
    /// the call.
    public func loadSMF(_ bytes: [UInt8]) {
        if let player {
            fluid_player_stop(player)
            delete_fluid_player(player)
        }
        let p = new_fluid_player(synth)
        bytes.withUnsafeBufferPointer { buf in
            _ = fluid_player_add_mem(p, buf.baseAddress, buf.count)
        }
        player = p
    }

    public func playerPlay() {
        guard let player else { return }
        fluid_player_play(player)
    }

    public func playerStop() {
        guard let player else { return }
        fluid_player_stop(player)
    }

    /// Seek to an absolute SMF tick. Host-driven loop wrap and seek both go
    /// through here (FluidSynth's own `set_loop` loops the whole file only).
    public func playerSeek(tick: Int) {
        guard let player else { return }
        fluid_player_seek(player, Int32(tick))
    }

    /// Current SMF tick — the transport clock the cursor timer polls.
    public var playerCurrentTick: Int {
        guard let player else { return 0 }
        return Int(fluid_player_get_current_tick(player))
    }

    /// Scale playback speed relative to the SMF's own tempo map
    /// (`FLUID_PLAYER_TEMPO_INTERNAL`), matching the Android engine.
    public func playerSetRate(_ rate: Double) {
        guard let player else { return }
        fluid_player_set_tempo(
            player, Int32(FLUID_PLAYER_TEMPO_INTERNAL.rawValue), rate,
        )
    }
}
