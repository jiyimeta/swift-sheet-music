import AVFoundation
import Foundation
import SheetMusicMIDI

/// Bridges `FluidSynthEngine` into an `AVAudioEngine` graph: an
/// `AVAudioSourceNode` pulls stereo float audio from `fluid_synth_write_float`
/// on the render thread, while transport (`fluid_player`) is driven from the
/// main actor. This is the Apple analogue of the Android engine's
/// FluidSynth + Oboe wiring.
///
/// Phase 1 scope: attach into a graph, load a SoundFont + rendered SMF, start,
/// and report the transport tick. Full feature parity (loop / seek / rate /
/// mixer / tuning / export) lands in a later phase behind a shared protocol.
@MainActor
public final class FluidSynthBackend {
    /// The synth wrapper. `nonisolated` storage so the `@Sendable` render block
    /// can call `render(...)` off the main actor (FluidSynth is thread-safe).
    private nonisolated let engine: FluidSynthEngine

    /// Audio source feeding the host graph. Connect this into a mixer.
    public let sourceNode: AVAudioSourceNode

    public init(sampleRate: Double) {
        let engine = FluidSynthEngine(sampleRate: sampleRate)
        self.engine = engine

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2,
        ) else {
            preconditionFailure(
                "stereo float32 format unavailable at \(sampleRate) Hz",
            )
        }
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, abListPtr in
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

    /// Load (or reload) the full-GM SoundFont. Returns the FluidSynth `sfid`.
    @discardableResult
    public func loadSoundFont(_ url: URL) -> Int32 {
        engine.loadSoundFont(url.path)
    }

    /// Load the rendered (and playback-post-processed) SMF into the transport.
    public func loadSequence(_ midi: MidiFile) throws {
        try engine.loadSMF([UInt8](MidiWriter.write(midi)))
    }

    /// Begin playing the loaded sequence from its current position.
    public func start() {
        engine.playerPlay()
    }

    /// Stop the transport (does not tear down the synth).
    public func stop() {
        engine.playerStop()
    }

    /// Current SMF tick — the transport clock a cursor timer polls.
    public var currentTick: Int {
        engine.playerCurrentTick
    }
}
