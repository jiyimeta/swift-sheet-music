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
        return try MidiWriter.write(midi)
    }
}

#if os(Android)
    import CJNI

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeRenderMidi")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeRenderMidi(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        guard let bytes = try? AudioMidiBridge.renderMidi(score: score) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        return makeJByteArray(env: envPtr, bytes: bytes)
    }
#endif
