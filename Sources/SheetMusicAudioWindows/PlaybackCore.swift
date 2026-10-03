import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import Synchronization

/// What the render thread and the engine's control calls share, behind one lock, and the render callback itself.
///
/// **Threading.** One `Mutex` (an SRWLOCK on Windows) around `Shared` — no lock-free queue, the SwiftySynth model.
/// The render thread holds it for a whole device callback; a control call holds it only to swap small values and send
/// the few MIDI messages that go with them. Nothing slow happens under it: rendering an SMF in Swift and loading a
/// SoundFont (`sfload`) are done before, deleting a synth after. The exceptions are `new_fluid_player` /
/// `delete_fluid_player` (see `PlayerHandle.make`), which FluidSynth requires to be serialized with rendering, and
/// which cost microseconds.
///
/// **Time.** The render callback works in 64-frame chunks (`FLUID_BUFSIZE`): FluidSynth advances each player once per
/// such block, so between two chunks both players' positions are settled, and the transport decisions
/// (`PlaybackTransportStepper`: count-in handover, loop wrap, end of score) and the preview note-off deadlines are
/// taken there — within 1.3 ms at 48 kHz, on the sample clock, and never on the host's UI thread.
final class PlaybackCore: @unchecked Sendable {
    /// Frames per render chunk: FluidSynth's `FLUID_BUFSIZE`, the granularity its players move at.
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
    /// What the two players were made from, to make a fresh one from (`Shared.stopPlayers`).
    var sequences: LoadedSequences
    var scorePlayer: PlayerHandle
    /// The metronome's plain sequence: the score's tempo map and the click on every beat.
    var bodyMetronome: PlayerHandle
    /// The sequence of the last count-in play: the count-in's bars, then the body's clicks shifted behind them. Kept
    /// after its handover until the next jump, then parked; deleted by the next count-in, prepare or teardown.
    var countInMetronome: PlayerHandle?
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

/// A seek asked for while the players run, carried out by the render thread between two chunks: FluidSynth refuses a
/// second `fluid_player_seek` on a playing player until its next block has carried out the first.
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

/// A preview's MIDI message kept back until a stopped score player has rendered its block
/// (`Shared.scoreStopUnrendered`).
enum HeldPreviewMessage: Sendable {
    case noteOn(channel: Int32, pitch: Int32, velocity: Int32)
    case noteOff(channel: Int32, pitch: Int32)
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
    /// The metronome plays `session.countInMetronome` rather than `bodyMetronome`.
    var usingCountInMetronome = false
    /// How far the playing metronome sequence runs ahead of the score's: the count-in sequence's shift, 0 for the body.
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
    /// A score player stopped while playing has yet to render its next block, in which FluidSynth sends All Sound Off
    /// on every channel it played on (`PlayerHandle`): a preview sent before then is cut with the score's notes — a
    /// held preview started in the same moment as a pause, most of the time.
    var scoreStopUnrendered = false
    /// The previews' messages sent while `scoreStopUnrendered`, in order; they go out right after that block. Room is
    /// reserved up front and kept on every clear: the render thread can append one too (a tap's note-off due in the
    /// chunk whose end-of-score stop set the hold), and must not allocate under the lock.
    var heldPreviewMessages: [HeldPreviewMessage] = {
        var messages: [HeldPreviewMessage] = []
        messages.reserveCapacity(16)
        return messages
    }()

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
