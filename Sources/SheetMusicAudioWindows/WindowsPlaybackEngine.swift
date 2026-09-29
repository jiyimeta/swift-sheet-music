import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicMIDI

/// Score playback on Windows: FluidSynth renders, WASAPI plays, and the cursor follows the device clock.
///
/// The Windows counterpart of the Apple `PlaybackEngine` (SheetMusicAudioApple) and of `AndroidPlaybackEngine`
/// (Android/SheetMusicAudioAndroid), built the way Android's is: the SMF comes from `AudioMidiBridge.renderMidi` with
/// its channels on the live channel plan, one FluidSynth synth plays it through FluidSynth's own MIDI player, and
/// positions translate through `PlaybackClock`. What differs is only what cannot be shared — the output (WASAPI in
/// place of AudioTrack) and the clock (`IAudioClock`, which counts what the device has played).
///
/// So far this is the roadmap's W0-5 probe surface: load, play, pause, stop and the position. Seek, loop, the mixer,
/// the metronome and count-in, transposition and tuning come with the Windows app's playback (its Phase 2), and each
/// is meant to come from the code the Apple and Android engines already share rather than from a third copy.
public final class WindowsPlaybackEngine: @unchecked Sendable {
    /// Where playback is, by the device clock.
    public struct Position: Sendable, Equatable {
        /// Seconds into the sequence the synth plays — repeats and jumps expanded — that the device has played.
        public let playerSeconds: Double
        /// The measure sounding now (0-based), `nil` with no score loaded.
        public let measureIndex: Int?
        /// The notated position sounding now.
        public let cursor: ScoreCursor?
    }

    /// What the output looks like, for a probe to report.
    public struct Diagnostics: Sendable {
        public let sampleRate: Double
        public let bufferFrames: Int
        public let latencySeconds: Double
        public let underruns: Int
    }

    private let renderer: FluidSynthRenderer
    private let device: AudioDeviceStream
    private let lock = NSLock()
    // Guarded by `lock`.
    private var clock: PlaybackClock?
    private var plan: LiveChannelPlan?
    private var midi: Data?

    /// Opens the default output device and a synth at its rate with the SoundFont at `soundFontPath`.
    public init(soundFontPath: String) throws {
        // The device decides the rate and the synth has to be made at it, yet the device takes its render function
        // up front — so that function reaches the synth through a slot filled in once the synth exists. Nothing
        // renders before `play`, by which time the slot is full.
        let slot = RendererSlot()
        device = try AudioDeviceStream { buffer, frames in
            slot.render(into: buffer, frames: frames)
        }
        renderer = try FluidSynthRenderer(sampleRate: device.sampleRate, soundFontPath: soundFontPath)
        slot.renderer = renderer
    }

    public func load(_ score: Score) throws {
        let plan = LiveChannelPlan.build(score: score)
        let midi = try AudioMidiBridge.renderMidi(score: score)
        let clock = PlaybackClock(score: score)
        lock.lock()
        self.clock = clock
        self.plan = plan
        self.midi = midi
        lock.unlock()
        renderer.configure(plan)
        try rewind()
    }

    /// Starts or resumes. The player starts with the first frames rendered, which is when the device clock starts
    /// counting too, so the clock's seconds are the sequence's seconds.
    public func play() throws {
        renderer.play()
        try device.start()
    }

    /// Stops the device where it is. The synth and the sequence freeze with it (the player advances only by frames
    /// rendered), so `play` resumes exactly there.
    public func pause() {
        device.stop()
    }

    /// Stops and goes back to the start of the sequence.
    public func stop() throws {
        try rewind()
    }

    /// Silences the synth and puts both the sequence and the device clock back at zero, so they start together again.
    private func rewind() throws {
        device.stop()
        renderer.allNotesOff()
        device.reset()
        lock.lock()
        let midi = midi
        lock.unlock()
        if let midi {
            try renderer.load(midi: midi)
        }
    }

    public var position: Position {
        let seconds = device.playedSeconds
        lock.lock()
        let clock = clock
        lock.unlock()
        return Position(
            playerSeconds: seconds,
            measureIndex: clock?.measureIndex(atPlayerSeconds: seconds),
            cursor: clock?.cursor(atPlayerSeconds: seconds),
        )
    }

    /// The length of the sequence the synth plays: longer than the notated length on a score with repeats.
    public var totalPlayerSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return clock?.totalPlayerSeconds ?? 0
    }

    /// Whether the device clock has reached the end of the sequence — the end as the score measures it, repeats
    /// expanded, which is where Android stops too (`unrolledTotalTicks`). Not FluidSynth's own "done": its player
    /// runs on to the SMF's last event, which on the sample score it reached 37 s after the score's end.
    public var isAtEnd: Bool {
        let total = totalPlayerSeconds
        return total > 0 && device.playedSeconds >= total
    }

    public var isRunning: Bool {
        device.isRunning
    }

    public var diagnostics: Diagnostics {
        Diagnostics(
            sampleRate: device.sampleRate,
            bufferFrames: device.bufferFrames,
            latencySeconds: device.latencySeconds,
            underruns: device.underruns,
        )
    }

    /// The program each strip's channel is on now, as `(channel, expected, actual)` — for checking that the
    /// engine's programs survived the player taking up the sequence.
    public var channelPrograms: [(channel: Int, expected: Int, actual: Int?)] {
        lock.lock()
        let strips = plan?.strips ?? []
        lock.unlock()
        return strips.map { strip in
            (strip.liveChannel, strip.instrument.channel.program, renderer.program(onChannel: strip.liveChannel))
        }
    }
}

/// Hands the render thread the synth that is made after the device it renders for. Written once, in the engine's
/// `init`, before anything can render.
private final class RendererSlot: @unchecked Sendable {
    var renderer: FluidSynthRenderer?

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        if let renderer {
            renderer.render(into: buffer, frames: frames)
        } else {
            buffer.update(repeating: 0, count: frames * 2)
        }
    }
}
