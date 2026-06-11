import Foundation
import SheetMusicCore
import SheetMusicMIDI

// MARK: - T14: MIDI render with channel relabeling

extension AudioMidiBridge {
    /// Rewrites every channel-bearing event's channel field to
    /// `trackIdx & 0x0F` so each MIDI track gets a unique channel
    /// on the Android audio engine.
    static func relabelChannelsToTrackIndex(_ midi: inout MidiFile) {
        for trackIdx in midi.tracks.indices {
            let ch = trackIdx & 0x0F
            for eventIdx in midi.tracks[trackIdx].events.indices {
                let event = midi.tracks[trackIdx].events[eventIdx].event
                let relabeled: MidiEvent
                switch event {
                case let .noteOn(_, pitch, velocity):
                    relabeled = .noteOn(channel: ch, pitch: pitch, velocity: velocity)
                case let .noteOff(_, pitch, velocity):
                    relabeled = .noteOff(channel: ch, pitch: pitch, velocity: velocity)
                case let .controlChange(_, controller, value):
                    relabeled = .controlChange(
                        channel: ch, controller: controller, value: value,
                    )
                case let .programChange(_, program):
                    relabeled = .programChange(channel: ch, program: program)
                case let .pitchBend(_, value):
                    relabeled = .pitchBend(channel: ch, value: value)
                default:
                    relabeled = event
                }
                midi.tracks[trackIdx].events[eventIdx].event = relabeled
            }
        }
    }

    /// Render `score` → SMF bytes, relabeling channels by track index
    /// so each track has a deterministic unique MIDI channel.
    static func renderMidi(score: Score) throws -> Data {
        var midi = try MidiRenderer.render(score: score)
        relabelChannelsToTrackIndex(&midi)
        // Strip the baked-in CC 7 / tick-0 program on each staff's (relabeled) channel so the live
        // FluidSynth mixer is the sole authority on per-staff volume — otherwise the SMF's tick-0
        // CC 7 re-fires on the first play and clobbers a volume the user set before playing. The
        // engine seeds the score's channel volume into the synth at prepare instead. Mirrors the
        // iOS engine (shared `MidiSynthPostProcess`). One track per staff → channel == trackIdx.
        let mixerManagedChannels = Set(midi.tracks.indices.map { $0 & 0x0F })
        MidiSynthPostProcess.apply(midi: &midi, mixerManagedChannels: mixerManagedChannels)
        return try MidiWriter.write(midi)
    }
}

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderMidi(...)` call site. Returns an
/// empty `Data` when the score handle is unknown or rendering throws.
public func nativeRenderMidi(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard let bytes = try? AudioMidiBridge.renderMidi(score: score) else {
        return Data()
    }
    return bytes
}
