import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import Synchronization

/// What the render thread and the engine's control calls share, behind one lock, and the render callback itself.
///
/// **Threading.** One `Mutex` (an SRWLOCK on Windows) around `Shared` — no lock-free queue, the SwiftySynth model.
/// The render thread holds it for a whole device callback; a control call holds it only to swap small values and send
/// the few MIDI messages that go with them. Nothing slow happens under it: rendering and parsing an SMF and loading a
/// SoundFont are done before, deleting a synth after. The exception is attaching a sequence (`PlayerHandle.make`),
/// which allocates its sequencer.
///
/// **Time.** The render callback works in 64-frame chunks, so between two chunks both sequences' positions are
/// settled, and the transport decisions (`PlaybackTransportStepper`: count-in handover, loop wrap, end of score) and
/// the preview note-off deadlines are taken there — within 1.3 ms at 48 kHz, on the sample clock, and never on the
/// host's UI thread. (64 was FluidSynth's `FLUID_BUFSIZE`, the granularity its players moved at; SwiftySynth renders
/// any count, and the chunk stays the decision grid.)
final class PlaybackCore: @unchecked Sendable {
    /// Frames per render chunk: the grid the render thread's decisions are taken on.
    static let chunkFrames = 64

    let shared = Mutex(Shared())

    /// Interleaved stereo scratch for the metronome synth's chunk. Render thread only, under the lock.
    private let metronomeScratch: UnsafeMutablePointer<Float>

    init() {
        metronomeScratch = .allocate(capacity: Self.chunkFrames * 2)
        metronomeScratch.initialize(repeating: 0, count: Self.chunkFrames * 2)
    }

    deinit {
        metronomeScratch.deallocate()
    }

    /// The device callback: fills `frames` (a multiple of `chunkFrames`) interleaved stereo frames into `buffer`.
    /// Called on the output thread only.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let scratch = metronomeScratch
        let outcome = shared.withLock { shared in
            shared.render(into: buffer, frames: frames, scratch: scratch)
        }
        // Outside the lock: both are host code, which may call back into the engine.
        if let level = outcome.level {
            outcome.levelHandler?(level)
        }
        if outcome.reachedEnd {
            outcome.onEvent?(.reachedEnd)
        }
    }

    /// An export's pull: `frames` (a multiple of `chunkFrames`) through the same `Shared.render` the device thread
    /// calls, answering whether there was anything to render (a torn-down engine has no session and renders silence),
    /// whether the transport reached its end in them, where it is now (unrolled), and whether a count-in is still
    /// sounding (the score parked at its start, which an export does not take for a stall). Nothing goes to the host:
    /// an export reports through its own progress, and its end is not playback's.
    func renderOffline(
        into buffer: UnsafeMutablePointer<Float>, frames: Int,
    ) -> (hasSession: Bool, reachedEnd: Bool, tick: Int, countingIn: Bool) {
        let scratch = metronomeScratch
        return shared.withLock { shared in
            let outcome = shared.render(into: buffer, frames: frames, scratch: scratch)
            return (shared.session != nil, outcome.reachedEnd, shared.reportedScoreTick, shared.countIn != nil)
        }
    }

    /// Hands `event` to the host's `onEvent`, on the calling thread.
    func emit(_ event: WindowsPlaybackEngine.Event) {
        let handler = shared.withLock { $0.onEvent }
        handler?(event)
    }

    /// Calls the host's `onOutputDeviceRemoved`, on the calling thread.
    func emitDeviceRemoved() {
        let handler = shared.withLock { $0.onOutputDeviceRemoved }
        handler?()
    }

    /// Routes one of the output's notices to the host.
    func deliver(_ notice: AudioDeviceStream.Notice) {
        switch notice {
        case .lost:
            emit(.deviceLost)
        case .removed:
            emitDeviceRemoved()
        case .recovered:
            emit(.deviceRecovered)
        }
    }
}

/// What one render callback leaves for the host, delivered once the lock is released.
struct RenderOutcome: Sendable {
    var level: MixLevel?
    var levelHandler: (@Sendable (MixLevel) -> Void)?
    var reachedEnd = false
    var onEvent: (@Sendable (WindowsPlaybackEngine.Event) -> Void)?
}

/// The synths and players a prepared score plays through. Replaced whole by a prepare or a SoundFont reload.
struct Session: Sendable {
    var score: SynthHandle
    var metronome: SynthHandle
    var scorePlayer: PlayerHandle
    /// The metronome synth's one sequence: the plain one (the score's tempo map and the click on every beat), or —
    /// from a count-in play on, until the next prepare — the count-in's, which carries the whole body behind its
    /// first pass (`MetronomeSequenceBuilder.countInSequenceWithWholeBody`), so nothing is attached again to wrap,
    /// seek or play on from it.
    var metronomePlayer: PlayerHandle
    /// Where the whole body starts in `metronomePlayer`'s sequence: 0 in the plain one. Every position but a count-in's
    /// first pass maps through it (`MetronomeSequenceBuilder.metronomeTick(forScoreTick:offset:)`).
    var metronomeWholeBodyOffsetTicks = 0
}

/// One mixer strip's live channel and what `reassertChannelState` asserts on it.
struct StripSlot: Sendable {
    let kind: MixerChannel.Kind
    let channel: Int32
    let isDrum: Bool
    /// The declared bank, honored as Android's `FluidSynthEngine` does; drums always select from bank 128.
    let bank: Int32
    /// The tuning RPN burst for this channel at the engine's current tuning and transposition
    /// (`MasterTuning.rpnControlChanges`), kept ready so a reassert on the render thread allocates nothing.
    var tuning: [MasterTuning.CC]
}

/// A seek asked for while the players run, carried out by the render thread between two chunks, after notes off — so
/// it lands where the stepper's decisions are taken, never between them.
struct DeferredSeek: Sendable {
    let scoreTick: Int
    let metronomeTick: Int
}

/// A tap preview's note-off, due once the render thread has rendered `frame` frames in total.
struct PreviewDeadline: Sendable {
    let generation: UInt64
    let frame: Int64
}

/// The held preview (`previewNoteOn`), which ends only on its own `previewNoteOff`.
struct SustainedPreview: Sendable {
    let staff: Int
    let channel: UInt8
    let pitch: UInt8
}

/// Everything behind `PlaybackCore.shared`. Every method here runs under that lock.
struct Shared: Sendable {
    // MARK: Synths and players

    var session: Session?
    var sampleRate = AudioDeviceStream.fallbackSampleRate
    /// Frames rendered since the stream started — the clock preview deadlines count on.
    var renderedFrames: Int64 = 0

    // MARK: Transport

    var state: PlaybackState = .stopped
    /// The score player has been played and not stopped since.
    var scoreRunning = false
    /// A count-in still sounding: the score player waits, parked at `countIn.scoreStartTick`.
    var countIn: PlaybackTransportStepper.CountIn?
    /// How far the metronome's sequence runs ahead of the score's now: a count-in's first pass's shift
    /// (`preRollTicks - baseTick`) until the first jump, else `session.metronomeWholeBodyOffsetTicks`.
    var metronomeOffsetTicks = 0
    /// Where a seek sent the score player that it has not carried out yet. Reported in place of the player's own tick,
    /// which trails a seek by one block while playing and indefinitely while stopped.
    var pendingScoreTick: Int? = 0
    var deferredSeek: DeferredSeek?
    /// Whether `currentCursor` reports anything: false after a stop, as the Apple engine's `currentCursor` is nil.
    var hasCursor = false
    /// A jump has happened whose controller chase may have overwritten channel state; reassert once the score player
    /// has carried it out.
    var reassertPending = false
    var rate: Float = 1
    /// The unrolled end of the score: `max(unroll.totalUnrolledTicks, timeline.totalTicks)`, as the Apple engine stops.
    var totalTicks = 0
    var loopRange: LoopRange?
    var transportLoop: TransportLoop?

    // MARK: Channels

    var strips: [StripSlot] = []
    var mixerChannels: [MixerChannel] = []
    var tuningCents: Double = 0
    var transposeSemitones = 0
    var metronomeMuted = false
    var metronomeVolume: Float = 1

    // MARK: Master stage and host hooks

    var outputGain: Float = 1
    var outputStage: MasterOutputStage = .none
    var levelHandler: (@Sendable (MixLevel) -> Void)?
    var onEvent: (@Sendable (WindowsPlaybackEngine.Event) -> Void)?
    var onOutputDeviceRemoved: (@Sendable () -> Void)?

    // MARK: Previews

    var previewPolicy = NotePreviewPolicy()
    var previewDeadline: PreviewDeadline?
    var sustainedPreview: SustainedPreview?

    // MARK: Counters (diagnostics and the probe)

    var loopWraps = 0
    var lastHandoverLateTicks: Int?
    /// The score tick the last wrap was decided at (at or past the loop's end by less than one chunk).
    var lastWrapDetectedTick: Int?
    /// The score player's tick once it had carried out the last wrap's seek.
    var lastWrapLandingTick: Int?
    var awaitingWrapLanding = false
    /// The largest sample magnitude leaving the output stage in the last callback that ran it (post-shaping).
    var lastOutputPeak: Float = 0
    /// Recording while set: the probe's per-chunk clock trace (`WindowsPlaybackEngine.probeStartClockTrace`).
    var clockTrace: ClockTrace?
}
