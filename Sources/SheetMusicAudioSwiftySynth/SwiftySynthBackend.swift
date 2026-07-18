import AVFoundation
import Foundation
import os
import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicMIDI
import SwiftySynth

/// `SynthBackend` implementation backed by SwiftySynth — a pure-Swift, MIT
/// SoundFont2 synthesizer (a MeltySynth port). Being Foundation-only it runs on
/// iOS as well as macOS and is App-Store clean (unlike FluidSynth's LGPL), so it
/// is the default stealing-free backend on Apple platforms.
///
/// An `AVAudioSourceNode` pulls stereo float audio on the render thread; the
/// `MidiFileSequencer` (fed the rendered SMF) advances the transport and
/// dispatches events. SwiftySynth is **not** thread-safe, so every access to the
/// synthesizer / sequencer — from the render thread AND the main actor (mixer,
/// preview, transport) — is serialized by a single `OSAllocatedUnfairLock`.
@MainActor
public final class SwiftySynthBackend: SynthBackend {
    /// Everything the render thread and the main actor share. Guarded by `lock`;
    /// never touched outside `lock.withLockUnchecked`.
    private struct Shared {
        var synthesizer: Synthesizer?
        var sequencer: MidiFileSequencer?
        var isPlaying = false
    }

    /// The one lock serializing all SwiftySynth access. `Sendable`, so the
    /// `@Sendable` render block can capture it; the non-`Sendable` `Shared`
    /// (it holds a `Synthesizer`) lives inside it via `uncheckedState`.
    private let lock = OSAllocatedUnfairLock(uncheckedState: Shared())

    private let sampleRate: Double
    /// Tick↔seconds for the loaded score (SwiftySynth's clock is seconds).
    private var timeline: PlaybackTimeline?

    public let sourceNode: AVAudioSourceNode
    public var outputNode: AVAudioNode {
        sourceNode
    }

    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        sourceNode = Self.makeSourceNode(lock: lock, sampleRate: sampleRate)
    }

    /// Build the render source node in a `nonisolated` context so its render
    /// block does NOT inherit `@MainActor` isolation — a main-actor closure
    /// traps (EXC_BREAKPOINT) the first time the real audio render thread pulls
    /// it. The block only captures the `Sendable` lock.
    private nonisolated static func makeSourceNode(
        lock: OSAllocatedUnfairLock<Shared>, sampleRate: Double,
    ) -> AVAudioSourceNode {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2,
        ) else {
            preconditionFailure("stereo float32 format unavailable at \(sampleRate) Hz")
        }
        return AVAudioSourceNode(format: format) { _, _, frameCount, abListPtr in
            let abl = UnsafeMutableAudioBufferListPointer(abListPtr)
            guard abl.count >= 2,
                  let leftRaw = abl[0].mData,
                  let rightRaw = abl[1].mData
            else { return noErr }
            let count = Int(frameCount)
            let left = UnsafeMutableBufferPointer(
                start: leftRaw.assumingMemoryBound(to: Float.self), count: count,
            )
            let right = UnsafeMutableBufferPointer(
                start: rightRaw.assumingMemoryBound(to: Float.self), count: count,
            )
            lock.withLockUnchecked { shared in
                if shared.isPlaying, let sequencer = shared.sequencer {
                    // Advances the transport, dispatches due events, renders.
                    sequencer.render(left: left, right: right)
                } else if let synthesizer = shared.synthesizer {
                    // Paused/stopped: still render so release tails ring out,
                    // but don't advance the transport.
                    synthesizer.render(left: left, right: right)
                } else {
                    left.update(repeating: 0)
                    right.update(repeating: 0)
                }
            }
            return noErr
        }
    }

    // MARK: SynthBackend

    public func attach(to engine: AVAudioEngine) {
        engine.attach(sourceNode)
    }

    public func prepare(soundfontURL: URL?, drumChannels _: Set<UInt8>) {
        // SwiftySynth resolves percussion on MIDI channel 9 automatically
        // (`Synthesizer.percussionChannel`), so `drumChannels` is unused.
        guard let soundfontURL,
              let data = try? Data(contentsOf: soundfontURL),
              let soundFont = try? SoundFont(data: data),
              let settings = try? SynthesizerSettings(
                  sampleRate: Int(sampleRate), maximumPolyphony: 256,
              ),
              let synthesizer = try? Synthesizer(soundFont: soundFont, settings: settings)
        else {
            lock.withLockUnchecked { $0.synthesizer = nil; $0.sequencer = nil; $0.isPlaying = false }
            return
        }
        let sequencer = MidiFileSequencer(synthesizer: synthesizer)
        lock.withLockUnchecked { shared in
            shared.synthesizer = synthesizer
            shared.sequencer = sequencer
            shared.isPlaying = false
        }
    }

    public func loadSequence(_ midi: SheetMusicMIDI.MidiFile, timeline: PlaybackTimeline) {
        self.timeline = timeline
        guard let bytes = try? MidiWriter.write(midi),
              let smf = try? SwiftySynth.MidiFile(data: bytes)
        else { return }
        lock.withLockUnchecked { shared in
            shared.sequencer?.play(smf, loop: false)
            shared.isPlaying = false
        }
    }

    public func play() {
        lock.withLockUnchecked { $0.isPlaying = true }
    }

    public func pause() {
        lock.withLockUnchecked { $0.isPlaying = false }
    }

    public func stop() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.sequencer?.seek(to: .zero)
            shared.synthesizer?.noteOffAll(immediate: true)
        }
    }

    public func seek(toTick tick: Int) {
        guard let timeline else { return }
        let seconds = timeline.seconds(atTick: Double(tick))
        lock.withLockUnchecked { $0.sequencer?.seek(to: .seconds(seconds)) }
    }

    public var currentTick: Int {
        guard let timeline else { return 0 }
        let seconds = lock.withLockUnchecked { shared -> Double in
            guard let pos = shared.sequencer?.position else { return 0 }
            return Double(pos.components.seconds)
                + Double(pos.components.attoseconds) * 1e-18
        }
        return timeline.frame(atTime: seconds)?.tick ?? 0
    }

    public func setProgram(channel: UInt8, program: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.processMidiMessage(
                channel: Int(channel), command: 0xC0, data1: Int(program), data2: 0,
            )
        }
    }

    public func sendVolume(channel: UInt8, cc7: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.processMidiMessage(
                channel: Int(channel), command: 0xB0, data1: 7, data2: Int(cc7),
            )
        }
    }

    public func startNote(channel: UInt8, pitch: UInt8, velocity: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.noteOn(key: Int(pitch), velocity: Int(velocity), on: Int(channel))
        }
    }

    public func stopNote(channel: UInt8, pitch: UInt8) {
        lock.withLockUnchecked {
            $0.synthesizer?.noteOff(key: Int(pitch), on: Int(channel))
        }
    }

    public func teardown() {
        lock.withLockUnchecked { shared in
            shared.isPlaying = false
            shared.sequencer?.stop()
            shared.sequencer = nil
            shared.synthesizer = nil
        }
    }
}
