import SheetMusicAudioCore
import SheetMusicFoundation
import SheetMusicMIDI
import SwiftySynth

/// One SwiftySynth synthesizer, with an optional sequence playing on it, shaped for a host that drives it the way
/// Android's Kotlin engine drove a FluidSynth synth and its player: one synth per role (score, metronome), MIDI
/// messages and a SoundFont from a control thread, frames pulled from an audio thread.
///
/// **Threading.** One lock (`HostLock`) around everything. The render holds it for one output block; a control call
/// holds it to send a few messages. Nothing slow runs under it: an SMF is parsed and a SoundFont's synthesizer is built
/// before it is taken, and the only allocation under it is a sequence's sequencer, on attach.
///
/// **State that outlives a reset.** SwiftySynth's sequencer resets its synthesizer on play, seek and stop, and the host
/// programs a channel once (`HostChannelState`); every reset here is followed by sending that state again.
///
/// **Always a synthesizer.** Until a SoundFont loads — or when it fails to — the synth plays a silent placeholder font,
/// so an attached sequence still keeps time: a FluidSynth player ran on a synth with no font too, and the engine reads
/// the transport's tick to find the end of the score.
public final class HostedSynth: @unchecked Sendable {
    public let sampleRate: Int
    public let voicing: SwiftySynthVoicing

    /// The sequence attached to the synth: the parsed file, the tempo map its ticks are read with, and the sequencer
    /// driving the synthesizer through it.
    struct Attached {
        let id: Int
        let midi: SwiftySynth.MidiFile
        let tempoMap: SequenceTempoMap
        /// The SMF's last event tick, end-of-track included — the length a FluidSynth player reported.
        let totalTicks: Int
        var sequencer: MidiFileSequencer
        var isPlaying = false
    }

    private let lock = HostLock()
    // Everything below is guarded by `lock`.
    private var synthesizer: Synthesizer
    private var hostState = HostChannelState()
    private var gain: Float = 1
    private var isClosed = false
    private var attached: Attached?
    private var nextSequenceID = 1

    /// A synth of `voicing` rendering at `sampleRate` (16–192 kHz), silent until `loadSoundFont`. Nil for a sample rate
    /// SwiftySynth refuses.
    public init?(sampleRate: Int, voicing: SwiftySynthVoicing) {
        guard let placeholder = voicing.makeSynthesizer(soundFont: Self.silentFont, sampleRate: sampleRate) else {
            return nil
        }
        self.sampleRate = sampleRate
        self.voicing = voicing
        synthesizer = placeholder
    }

    /// A one-preset font whose samples are silence, standing in until a real one loads.
    private nonisolated(unsafe) static let silentFont: SoundFont = {
        let silence = [Int16](repeating: 0, count: 64)
        // swiftlint:disable:next force_try
        return try! SoundFont(data: ClickSoundFontBuilder.build(
            strong: silence, strongRate: 44100, weak: silence, weakRate: 44100,
        ))
    }()

    // MARK: - SoundFont

    /// Plays `font` from now on: a new synthesizer over it, the host's state sent to it, the gain carried over, and an
    /// attached sequence moved onto it where it stood. `false` when the synth is closed or SwiftySynth refuses the
    /// font.
    @discardableResult
    public func loadSoundFont(_ font: SoundFont) -> Bool {
        guard let built = voicing.makeSynthesizer(soundFont: font, sampleRate: sampleRate) else { return false }
        return lock.withLock {
            guard !isClosed else { return false }
            synthesizer = built
            synthesizer.masterVolume = gain
            if var attached {
                let position = attached.sequencer.position
                let speed = attached.sequencer.speed
                attached.sequencer = SwiftySynthVoicing.makeSequencer(driving: built)
                attached.sequencer.play(attached.midi, loop: false)
                attached.sequencer.speed = speed
                if position > .zero { attached.sequencer.seek(to: position) }
                self.attached = attached
            }
            replayHostState()
            return true
        }
    }

    // MARK: - Channel messages

    /// Selects `program` in `bank` on `channel` — 128 and up for a drum kit, which SwiftySynth sounds on the percussion
    /// channel only (`HostChannelState.replay`). Kept across resets. Reads the preset's samples in on a utility thread,
    /// so its first notes do not fault the font's pages in on the render thread — only when the selection changes, so
    /// a host that sends the same program again from its render thread (Windows' reassert) starts no task there.
    public func programSelect(channel: Int, bank: Int, program: Int) {
        let bankSelect = HostChannelState.bankSelect(channel: channel, bank: bank)
        let program = min(max(0, program), 127)
        let font: SoundFont? = lock.withLock {
            guard !isClosed else { return nil }
            let previous = hostState.program(channel: channel)
            hostState.recordProgram(channel: channel, bank: bank, program: program)
            synthesizer.processMidiMessage(channel: channel, command: 0xB0, data1: 0, data2: bankSelect)
            synthesizer.processMidiMessage(channel: channel, command: 0xC0, data1: program, data2: 0)
            if let previous, let now = hostState.program(channel: channel), previous == now { return nil }
            return synthesizer.soundFont
        }
        guard let font, font !== Self.silentFont else { return }
        let prefetch = PrefetchRequest(
            font: font, bank: HostChannelState.effectiveBank(channel: channel, bankSelect: bankSelect), patch: program,
        )
        Task.detached(priority: .utility) { prefetch.run() }
    }

    /// Sends a control change now and keeps it across resets (channel-mode messages are sent but not kept).
    public func controlChange(channel: Int, controller: Int, value: Int) {
        lock.withLock {
            guard !isClosed else { return }
            hostState.recordControlChange(channel: channel, controller: controller, value: value)
            synthesizer.processMidiMessage(channel: channel, command: 0xB0, data1: controller, data2: value)
        }
    }

    /// The value the host last set for `controller` on `channel`, else a reset channel's; -1 off the 16 channels.
    public func controllerValue(channel: Int, controller: Int) -> Int {
        lock.withLock { hostState.controllerValue(channel: channel, controller: controller) }
    }

    /// The synthesizer's output gain (`masterVolume`); 1 is unity.
    public func setGain(_ gain: Float) {
        lock.withLock {
            self.gain = max(0, gain)
            synthesizer.masterVolume = self.gain
        }
    }

    public func noteOn(channel: Int, key: Int, velocity: Int) {
        lock.withLock {
            guard !isClosed else { return }
            synthesizer.noteOn(key: key, velocity: velocity, on: channel)
        }
    }

    public func noteOff(channel: Int, key: Int) {
        lock.withLock {
            guard !isClosed else { return }
            synthesizer.noteOff(key: key, on: channel)
        }
    }

    /// Puts `channel`'s pitch wheel at `value` (14-bit, 8192 the center) for an audition — a microtonal note's offset,
    /// or the center that undoes one (`PreviewPlan.pitchBends`). Sends the bend sensitivity first
    /// (`Synthesizer.sendAuditionPitchBend`), as the Apple backend does.
    ///
    /// Not kept across resets, unlike a control change: the next audition sets the wheel it needs, and a sequencer
    /// reset — play, seek, stop — puts it back to the center playback starts from, which is exactly what playback
    /// wants.
    public func pitchBend(channel: Int, value: Int) {
        lock.withLock {
            guard !isClosed else { return }
            synthesizer.sendAuditionPitchBend(channel: channel, value: UInt16(clamping: min(max(0, value), 16383)))
        }
    }

    /// Releases every note on `channel` (they ring out their release, as `fluid_synth_all_notes_off` lets them).
    public func allNotesOff(channel: Int) {
        lock.withLock {
            guard !isClosed else { return }
            synthesizer.noteOffAll(channel: channel, immediate: false)
        }
    }

    /// Cuts every sounding voice at once, releases included — MIDI's All Sound Off, on every channel.
    public func allSoundsOff() {
        lock.withLock {
            guard !isClosed else { return }
            synthesizer.noteOffAll(immediate: true)
        }
    }

    /// Back to a new synth's state: voices cut, every channel reset, and the host's record of what it set forgotten —
    /// for a host that reuses the synth for another score. The gain and an attached sequence are kept.
    public func resetHostState() {
        lock.withLock {
            guard !isClosed else { return }
            hostState = HostChannelState()
            synthesizer.reset()
        }
    }

    // MARK: - Read-backs

    /// The effective bank and program the host last selected on `channel` — what every reset sends back, so what the
    /// channel plays. Nil when the host selected none there.
    public func recordedProgram(channel: Int) -> (bank: Int, program: Int)? {
        lock.withLock { hostState.program(channel: channel) }
    }

    /// The coarse (semitones) and fine (cents) tuning the host's RPNs hold on `channel`.
    public func recordedTuning(channel: Int) -> (coarseSemitones: Int, fineCents: Double) {
        lock.withLock { hostState.tuning(channel: channel) }
    }

    /// Voices sounding now.
    public var activeVoiceCount: Int {
        lock.withLock { synthesizer.activeVoiceCount }
    }

    /// Whether a SoundFont loaded, rather than the silent placeholder playing.
    public var hasSoundFont: Bool {
        lock.withLock { synthesizer.soundFont !== Self.silentFont }
    }

    // MARK: - Render

    /// Renders `frames` stereo frames into `left` and `right`: through the attached sequence while it plays, else the
    /// synthesizer alone (note previews while stopped). Silence once closed. Allocates nothing.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLock { renderHoldingLock(left: left, right: right, frames: frames) }
    }

    /// Runs `body` holding the synth's lock — for a caller that must do something between taking it and rendering
    /// (JNI pins the output arrays only once the lock is held, so it never waits for a control call with the arrays
    /// pinned).
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    /// `render(left:right:frames:)` for a caller already inside `withLock`.
    public func renderHoldingLock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        guard !isClosed else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        let leftBuffer = UnsafeMutableBufferPointer(start: left, count: frames)
        let rightBuffer = UnsafeMutableBufferPointer(start: right, count: frames)
        if attached?.isPlaying == true, let sequencer = attached?.sequencer {
            sequencer.render(left: leftBuffer, right: rightBuffer)
        } else {
            synthesizer.render(left: leftBuffer, right: rightBuffer)
        }
    }

    // MARK: - Sequence

    /// Attaches the SMF in `smf`, parked at its start and not playing, in place of any sequence attached before (whose
    /// `HostedSequence` goes inert). Nil when the bytes are not an SMF SwiftySynth reads or the synth is closed.
    ///
    /// Attaching resets the synthesizer — notes still sounding stop — and sends the host's state again.
    public func attachSequence(smf: Data) -> HostedSequence? {
        Self.prepareSequence(smf: smf).flatMap(attach)
    }

    /// An SMF parsed for `attach(_:)`: what `attachSequence(smf:)` does before it takes the synth's lock, for a host
    /// that must attach under a lock of its own and keeps the parse out of it.
    public struct PreparedSequence: @unchecked Sendable {
        let midi: SwiftySynth.MidiFile
        let tempoMap: SequenceTempoMap
        let totalTicks: Int
    }

    /// Parses `smf`; nil when the bytes are not an SMF SwiftySynth reads.
    public static func prepareSequence(smf: Data) -> PreparedSequence? {
        guard let midi = try? SwiftySynth.MidiFile(data: smf), let tempoMap = SequenceTempoMap(smf: smf),
              let file = try? MidiReader.read(smf)
        else {
            return nil
        }
        let totalTicks = file.tracks.compactMap { $0.events.last?.tick }.max() ?? 0
        return PreparedSequence(midi: midi, tempoMap: tempoMap, totalTicks: totalTicks)
    }

    /// `attachSequence(smf:)` for a sequence parsed already. Allocates the sequencer, and nothing else. Nil once the
    /// synth is closed.
    public func attach(_ prepared: PreparedSequence) -> HostedSequence? {
        let id: Int? = lock.withLock {
            guard !isClosed else { return nil }
            let id = nextSequenceID
            nextSequenceID += 1
            let sequencer = SwiftySynthVoicing.makeSequencer(driving: synthesizer)
            sequencer.play(prepared.midi, loop: false)
            attached = Attached(
                id: id, midi: prepared.midi, tempoMap: prepared.tempoMap, totalTicks: prepared.totalTicks,
                sequencer: sequencer,
            )
            replayHostState()
            return id
        }
        return id.map { HostedSequence(synth: self, id: $0) }
    }

    /// Runs `body` on the attached sequence if it is still sequence `id`, under the lock; `fallback` otherwise.
    func withSequence<R>(_ id: Int, fallback: R, _ body: (inout Attached, Synthesizer) -> R) -> R {
        lock.withLock {
            guard !isClosed, var current = attached, current.id == id else { return fallback }
            let result = body(&current, synthesizer)
            attached = current
            return result
        }
    }

    /// Lets go of sequence `id` if it is still the attached one.
    func detach(_ id: Int) {
        lock.withLock {
            if attached?.id == id { attached = nil }
        }
    }

    /// Sends the host's channel state to the synthesizer again. Under the lock, after anything that reset it.
    func replayHostStateHoldingLock() {
        replayHostState()
    }

    private func replayHostState() {
        let synthesizer = synthesizer
        hostState.replay { channel, command, data1, data2 in
            synthesizer.processMidiMessage(channel: channel, command: command, data1: data1, data2: data2)
        }
    }

    // MARK: - Lifetime

    /// Silences the synth for good: renders zeros from now on, ignores every message, and lets go of its sequence.
    public func close() {
        lock.withLock {
            isClosed = true
            attached = nil
            synthesizer.noteOffAll(immediate: true)
        }
    }
}

/// Reads one preset's samples in, off the render thread. `SoundFont` is immutable once loaded but not declared
/// `Sendable`; this is where it crosses into the detached task.
private struct PrefetchRequest: @unchecked Sendable {
    let font: SoundFont
    let bank: Int
    let patch: Int

    func run() {
        font.prefetchSamples(bank: bank, patch: patch)
    }
}
