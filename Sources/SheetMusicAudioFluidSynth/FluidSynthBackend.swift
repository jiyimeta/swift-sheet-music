import AVFoundation
import Foundation
import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicMIDI

/// `SynthBackend` implementation backed by FluidSynth. An `AVAudioSourceNode`
/// pulls stereo float audio from `fluid_synth_write_float` on the render thread
/// while transport (`fluid_player`) is driven from the main actor — the Apple
/// analogue of the Android engine's FluidSynth + Oboe wiring.
///
/// FluidSynth's configurable 256-voice pool and lack of a process-global voice
/// recycler eliminate the AUMIDISynth stealing pathology. This type lives in the
/// opt-in, LGPL-2.1 `SheetMusicAudioFluidSynth` product; a host injects it into
/// `PlaybackEngine`, which never imports it.
@MainActor
public final class FluidSynthBackend: SynthBackend {
    /// `nonisolated` so the `@Sendable` render block can call `render(...)` off
    /// the main actor (FluidSynth is thread-safe via `synth.threadsafe-api`).
    private nonisolated let engine: FluidSynthEngine

    /// Audio source feeding the host graph.
    public let sourceNode: AVAudioSourceNode

    public var outputNode: AVAudioNode {
        sourceNode
    }

    public init(sampleRate: Double = 44100) {
        let engine = FluidSynthEngine(sampleRate: sampleRate)
        self.engine = engine
        sourceNode = Self.makeSourceNode(engine: engine, sampleRate: sampleRate)
    }

    /// Build the render source node in a `nonisolated` context so its render
    /// block does NOT inherit `FluidSynthBackend`'s `@MainActor` isolation.
    /// A closure created in the `@MainActor init` inherits main-actor isolation
    /// even when passed to `AVAudioSourceNode`'s `@Sendable` render-block
    /// parameter, so Swift inserts a main-actor executor assertion that TRAPS
    /// (EXC_BREAKPOINT) the first time the real audio render thread pulls the
    /// node. (Offline manual rendering runs the block on the caller's thread, so
    /// unit tests don't hit it — only a live engine's dedicated render thread
    /// does.) A `nonisolated static` factory keeps the block isolation-free.
    private nonisolated static func makeSourceNode(
        engine: FluidSynthEngine, sampleRate: Double,
    ) -> AVAudioSourceNode {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2,
        ) else {
            preconditionFailure(
                "stereo float32 format unavailable at \(sampleRate) Hz",
            )
        }
        return AVAudioSourceNode(format: format) { _, _, frameCount, abListPtr in
            let abl = UnsafeMutableAudioBufferListPointer(abListPtr)
            guard abl.count >= 2,
                  let leftRaw = abl[0].mData,
                  let rightRaw = abl[1].mData
            else { return noErr }
            engine.render(
                frameCount: Int(frameCount),
                left: leftRaw.assumingMemoryBound(to: Float.self),
                right: rightRaw.assumingMemoryBound(to: Float.self),
            )
            return noErr
        }
    }

    // MARK: SynthBackend

    public func attach(to engine: AVAudioEngine) {
        engine.attach(sourceNode)
    }

    public func prepare(soundfontURL: URL?, drumChannels: Set<UInt8>) {
        if let soundfontURL {
            engine.loadSoundFont(soundfontURL.path)
        }
        // FluidSynth resolves percussion by channel type, not a bank byte.
        for ch: UInt8 in 0 ..< 16 {
            let isDrum = drumChannels.contains(ch)
            engine.setChannelType(channel: ch, isDrum: isDrum)
            if !isDrum {
                // Seed a program so a tap preview before playback sounds
                // (mirrors the AUMIDISynth path's GM-piano seed). The SMF's
                // own program changes + the mixer override select the real one.
                engine.programSelect(channel: ch, bank: 0, program: 0)
            }
        }
    }

    public func loadSequence(_ midi: MidiFile, timeline _: PlaybackTimeline) {
        // FluidSynth's player reads the SMF's own division; `division` is
        // unused here but part of the seam for backends that need it.
        guard let bytes = try? MidiWriter.write(midi) else { return }
        engine.loadSMF([UInt8](bytes))
    }

    public func play() {
        engine.playerPlay()
    }

    public func pause() {
        // `fluid_player_stop` halts playback and retains the current tick; the
        // next `play()` resumes from there. (Refined with explicit seek in the
        // transport-parity phase if resume-from-position proves unreliable.)
        engine.playerStop()
    }

    public func stop() {
        engine.playerStop()
        engine.playerSeek(tick: 0)
    }

    public func seek(toTick tick: Int) {
        engine.playerSeek(tick: tick)
    }

    public var currentTick: Int {
        engine.playerCurrentTick
    }

    public func setProgram(channel: UInt8, program: UInt8) {
        engine.programSelect(channel: channel, bank: 0, program: program)
    }

    public func sendVolume(channel: UInt8, cc7: UInt8) {
        engine.controlChange(channel: channel, controller: 7, value: cc7)
    }

    public func startNote(channel: UInt8, pitch: UInt8, velocity: UInt8) {
        engine.noteOn(channel: channel, key: pitch, velocity: velocity)
    }

    public func stopNote(channel: UInt8, pitch: UInt8) {
        engine.noteOff(channel: channel, key: pitch)
    }

    public func teardown() {
        engine.playerStop()
    }
}
