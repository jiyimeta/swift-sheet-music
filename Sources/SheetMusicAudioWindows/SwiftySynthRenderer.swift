import Foundation
import SheetMusicAudioCore
import SheetMusicAudioSwiftySynthCore
import SwiftySynth

// The synths the Windows engine drives: one for the score and one for the metronome, each with one sequence attached
// at a time — SwiftySynth through `HostedSynth`, the host Android's engine drives, so a score sounds on Windows as it
// does on a Mac and a Pixel. The engine was written against FluidSynth's synth and player; these keep that shape
// (interleaved output, a seek the next played block carries out), so `Shared` did not change with the move. Who may
// call what, and when, is the engine's business (see `PlaybackCore`).

/// A SwiftySynth synth with the SoundFont loaded into it, and the room it renders a block in.
///
/// A value on purpose: nothing closes it behind the engine's back. The engine deletes it explicitly (`delete()`), once
/// nothing renders it any more.
struct SynthHandle: @unchecked Sendable {
    let host: HostedSynth
    /// Whether the SoundFont loaded. A synth without one plays nothing (SwiftySynth's silent placeholder), as the
    /// Apple and Android engines do; `diagnostics` says which it is.
    let soundFontLoaded: Bool
    /// The SoundFont this synth was asked to load, so a later prepare can tell whether it can keep the synth.
    let soundFontURL: URL?
    let sampleRate: Double
    let slot: SequenceSlot

    /// The output level on Windows, on both synths (SwiftySynth's `masterVolume`): the Mac's — 1, SwiftySynth's own
    /// level, which the Apple and Android apps play at (owner, 2026-11-04). Windows under FluidSynth (its gain 2.0)
    /// played 7.8–8.0 dB louder than the Mac on the three calibration scores; `CalibrationTests` holds the Mac's.
    static let windowsOutputGain: Float = 1

    /// Builds a synth at `sampleRate` and loads `soundFontURL` into it (read in place, memory-mapped). The score's has
    /// SwiftySynth's score voicing (256 voices, reverb and chorus); without `effects`, the metronome's (8 voices,
    /// dry) — what the Apple and Android engines' click synth is.
    ///
    /// - Throws: `WindowsAudioError.synth` for a sample rate SwiftySynth refuses. A SoundFont it cannot load is not an
    ///   error (see `soundFontLoaded`).
    static func make(sampleRate: Double, soundFontURL: URL?, effects: Bool = true) throws -> SynthHandle {
        guard let host = HostedSynth(sampleRate: Int(sampleRate.rounded()), voicing: effects ? .score : .metronome)
        else {
            throw WindowsAudioError.synth("SwiftySynth refused the sample rate \(sampleRate)")
        }
        host.setGain(windowsOutputGain)
        var loaded = false
        if let soundFontURL, let font = try? SoundFont(url: soundFontURL) {
            loaded = host.loadSoundFont(font)
        }
        return SynthHandle(
            host: host, soundFontLoaded: loaded, soundFontURL: soundFontURL, sampleRate: sampleRate,
            slot: SequenceSlot(),
        )
    }

    /// Silences the synth for good. Only once nothing renders it.
    func delete() {
        host.close()
    }

    /// Whether `other` is this same synth.
    func isSame(as other: SynthHandle) -> Bool {
        host === other.host
    }

    /// Renders `frames` frames into `out`, interleaved stereo, overwriting what is there — after carrying out a seek
    /// asked of its playing sequence (`PlayerHandle.seek`). Allocates nothing.
    @inline(__always)
    func write(frames: Int32, into out: UnsafeMutablePointer<Float>) {
        slot.carryOutPendingSeek(onlyIfPlaying: true)
        let total = Int(frames)
        var done = 0
        while done < total {
            let count = min(SequenceSlot.capacity, total - done)
            host.render(left: slot.left, right: slot.right, frames: count)
            let base = out + done * 2
            for index in 0 ..< count {
                base[index * 2] = slot.left[index]
                base[index * 2 + 1] = slot.right[index]
            }
            done += count
        }
    }

    func controlChange(channel: Int32, controller: Int32, value: Int32) {
        host.controlChange(channel: Int(channel), controller: Int(controller), value: Int(value))
    }

    /// Sends `messages` to `channel` in order — a tuning RPN burst (`MasterTuning.rpnControlChanges`). Allocates
    /// nothing; kept across the sequencer's resets (`HostChannelState`).
    func send(_ messages: [MasterTuning.CC], onChannel channel: Int32) {
        for message in messages {
            host.controlChange(channel: Int(channel), controller: Int(message.controller), value: Int(message.value))
        }
    }

    func noteOn(channel: Int32, pitch: Int32, velocity: Int32) {
        host.noteOn(channel: Int(channel), key: Int(pitch), velocity: Int(velocity))
    }

    func noteOff(channel: Int32, pitch: Int32) {
        host.noteOff(channel: Int(channel), key: Int(pitch))
    }

    /// Note-off on every sounding note of `channel` (`-1`: every channel); releases ring out.
    func allNotesOff(channel: Int32 = -1) {
        if channel >= 0 {
            host.allNotesOff(channel: Int(channel))
            return
        }
        for channel in 0 ..< 16 {
            host.allNotesOff(channel: channel)
        }
    }

    /// Silences every channel at once, releases included — MIDI's All Sound Off.
    func allSoundsOff() {
        host.allSoundsOff()
    }

    /// Selects `program` in `bank` (128 for drums) on `channel`, kept across the sequencer's resets. `false` when no
    /// SoundFont loaded (the channel then keeps what it had, as on Android).
    @discardableResult
    func selectProgram(channel: Int32, bank: Int32, program: Int32) -> Bool {
        guard soundFontLoaded else { return false }
        host.programSelect(channel: Int(channel), bank: Int(bank), program: Int(program))
        return true
    }

    /// Nothing to do: SwiftySynth sounds a drum kit on the percussion channel only, and the playback render puts every
    /// drumset there (`LiveChannelPlan`). FluidSynth needed the channel's type set.
    func setDrumChannel(_: Int32, isDrum _: Bool) {}

    /// Back to the state of a new synth: voices off, every channel reset, the host's record cleared.
    func systemReset() {
        host.resetHostState()
    }

    // MARK: Read-backs (probe)

    /// What the host set — what every reset sends back, so what the channel plays. SwiftySynth reads none of its
    /// channels' state back.
    func controller(_ controller: Int32, onChannel channel: Int32) -> Int? {
        let value = host.controllerValue(channel: Int(channel), controller: Int(controller))
        return value < 0 ? nil : value
    }

    func program(onChannel channel: Int32) -> (bank: Int, program: Int)? {
        host.recordedProgram(channel: Int(channel))
    }

    var activeVoiceCount: Int {
        host.activeVoiceCount
    }

    /// The channel's coarse (semitones) and fine (cents) tuning, as the tuning RPN set them.
    func tuning(onChannel channel: Int32) -> (coarse: Double, fine: Double) {
        let tuning = host.recordedTuning(channel: Int(channel))
        return (Double(tuning.coarseSemitones), tuning.fineCents)
    }
}

/// A synth's render scratch and the seek its sequence has been asked for and not carried out. Touched only under
/// `PlaybackCore`'s lock.
final class SequenceSlot: @unchecked Sendable {
    /// Frames per render pass: the engine's chunk, so a chunk is one pass.
    static let capacity = PlaybackCore.chunkFrames

    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    /// A seek asked of `sequence`, carried out by the next block it plays in, or by its next `play`.
    private(set) var pending: (sequence: HostedSequence, tick: Int)?

    init() {
        left = .allocate(capacity: Self.capacity)
        left.initialize(repeating: 0, count: Self.capacity)
        right = .allocate(capacity: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func request(_ sequence: HostedSequence, tick: Int) {
        pending = (sequence, tick)
    }

    func cancel(for sequence: HostedSequence) {
        if pending?.sequence === sequence { pending = nil }
    }

    func pendingTick(for sequence: HostedSequence) -> Int? {
        guard let pending, pending.sequence === sequence else { return nil }
        return pending.tick
    }

    /// Carries out the pending seek — while playing only, from the render: a seek resets the synthesizer (the chase),
    /// and a stopped sequence's must not cut a preview sounding while paused. A FluidSynth player likewise carried out
    /// a seek only in a block it played.
    func carryOutPendingSeek(onlyIfPlaying: Bool) {
        guard let pending, !onlyIfPlaying || pending.sequence.isPlaying else { return }
        self.pending = nil
        pending.sequence.seek(toTick: pending.tick)
    }
}

/// One SMF attached to a `SynthHandle` — the synth's only one: attaching another leaves this one inert.
///
/// A seek is a request the next block the sequence plays in carries out, or its next `play`; until then `tick` reports
/// the target, as the engine's own `pendingScoreTick` does for the score.
struct PlayerHandle: @unchecked Sendable {
    let sequence: HostedSequence
    let slot: SequenceSlot

    /// Parses `midi` for `make(on:prepared:rate:)` — outside the engine's lock.
    static func prepare(_ midi: Data) throws -> HostedSynth.PreparedSequence {
        guard let prepared = HostedSynth.prepareSequence(smf: midi) else {
            throw WindowsAudioError.synth("SwiftySynth could not read the MIDI")
        }
        return prepared
    }

    /// A sequence on `synth` playing `prepared`, at tempo scale `rate`, parked at its start, replacing what was
    /// attached. Allocates the sequencer and nothing else, so the engine calls it under its lock.
    static func make(
        on synth: SynthHandle, prepared: HostedSynth.PreparedSequence, rate: Float,
    ) throws -> PlayerHandle {
        guard let sequence = synth.host.attach(prepared) else {
            throw WindowsAudioError.synth("the synth is closed")
        }
        let handle = PlayerHandle(sequence: sequence, slot: synth.slot)
        handle.setTempo(rate)
        return handle
    }

    /// Lets go of the synth's transport (a no-op once another sequence is attached in its place).
    func delete() {
        slot.cancel(for: sequence)
        sequence.detach()
    }

    /// Plays from where it stands, or from where a pending seek puts it.
    func play() {
        slot.carryOutPendingSeek(onlyIfPlaying: false)
        sequence.play()
    }

    /// Stops a playing sequence and cuts the synth's voices; one that is not playing is left alone.
    func stop() {
        guard isPlaying else { return }
        sequence.stop()
    }

    /// Asks the sequence to jump to `tick`: carried out by the next block it plays in (or its next `play`), with the
    /// controller chase and the host's channel state after it. A second request before then replaces the first. A
    /// target past the end lands on the end.
    func seek(to tick: Int) {
        slot.request(sequence, tick: max(0, tick))
    }

    var tick: Int {
        slot.pendingTick(for: sequence) ?? sequence.currentTick
    }

    /// The SMF's length, known from the attach on.
    var totalTicks: Int {
        sequence.totalTicks
    }

    var isPlaying: Bool {
        sequence.isPlaying
    }

    /// Whether the sequence has run past its last event. Never while a seek is pending: the sequence is going
    /// somewhere else.
    var isDone: Bool {
        slot.pendingTick(for: sequence) == nil && sequence.isAtEnd
    }

    /// Scales the sequence's own tempo map by `rate`, as `AVAudioSequencer.rate` and Android's `setSpeed` do.
    func setTempo(_ rate: Float) {
        sequence.setSpeed(Double(rate))
    }
}
