import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

// Audio JNI bridge helpers. The testable logic lives outside `#if os(Android)`
// so host-platform tests can call the helpers directly. The `@_cdecl` JNI
// entry points are in `AudioMidiBridge+Render.swift` and
// `AudioMidiBridge+Timeline.swift`.

// MARK: - AudioMidiBridge namespace

enum AudioMidiBridge {}

// MARK: - T18: Note pitch lookup + earliest item

extension AudioMidiBridge {
    /// Returns `(pitch as UInt32) << 32 | (staffIndex as UInt32)`.
    /// Returns the sentinel `0xFFFFFFFFFFFFFFFF` (-1 as Int64) when
    /// the noteId no longer resolves.
    static func pitchAndStaffOfNote(score: Score, noteId: NoteID) -> Int64 {
        let invalid = Int64(bitPattern: 0xFFFF_FFFF_FFFF_FFFF)
        guard let staff = score[noteId.staff] else { return invalid }
        let flatIdx = score.allStaves.firstIndex {
            $0.address == noteId.staff
        } ?? -1
        guard flatIdx >= 0,
              noteId.measureIndex < staff.measures.count
        else { return invalid }
        let measure = staff.measures[noteId.measureIndex]
        guard noteId.voiceIndex < measure.voices.count else { return invalid }
        let voice = measure.voices[noteId.voiceIndex]
        guard noteId.elementIndex < voice.elements.count,
              case let .chord(chord) = voice.elements[noteId.elementIndex],
              noteId.noteIndexInChord < chord.notes.count
        else { return invalid }
        let pitch = UInt32(clamping: chord.notes[noteId.noteIndexInChord].pitch)
        let staffIdx = UInt32(flatIdx)
        return Int64(bitPattern: (UInt64(pitch) << 32) | UInt64(staffIdx))
    }

    static func earliestOf(score: Score, ids: [ScoreItemID]) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let earliest = timeline.earliest(of: ids) else { return Data() }
        return ScoreItemIDCodec.encode(earliest)
    }
}

// MARK: - @_cdecl JNI helpers + T18 entry points (Android only)

#if os(Android)
    import CJNI

    // JNI byte-array helpers — used by all @_cdecl functions in this module.

    func makeJByteArray(
        env: UnsafeMutablePointer<JNIEnv?>, bytes: Data,
    ) -> jbyteArray? {
        guard let envP = env.pointee else { return nil }
        let array = envP.pointee.NewByteArray(env, jsize(bytes.count))
        bytes.withUnsafeBytes { rawBuf in
            let typed = rawBuf.bindMemory(to: jbyte.self)
            envP.pointee.SetByteArrayRegion(
                env, array, 0, jsize(bytes.count), typed.baseAddress,
            )
        }
        return array
    }

    func readJByteArray(
        env: UnsafeMutablePointer<JNIEnv?>, array: jbyteArray,
    ) -> Data {
        guard let envP = env.pointee else { return Data() }
        let len = envP.pointee.GetArrayLength(env, array)
        guard len > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: Int(len))
        buf.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            base.withMemoryRebound(to: jbyte.self, capacity: Int(len)) { jp in
                envP.pointee.GetByteArrayRegion(env, array, 0, len, jp)
            }
        }
        return Data(buf)
    }

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativePitchAndStaffOfNote")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativePitchAndStaffOfNote(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ noteIdBytes: jbyteArray,
    ) -> jlong {
        let invalid = jlong(bitPattern: 0xFFFF_FFFF_FFFF_FFFF)
        guard let score = scoreTable.value(for: scoreHandle) else { return invalid }
        let data = readJByteArray(env: envPtr, array: noteIdBytes)
        guard !data.isEmpty else { return invalid }
        guard let noteId = try? PathIDCodecs.decode(data) else { return invalid }
        return AudioMidiBridge.pitchAndStaffOfNote(score: score, noteId: noteId)
    }

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeEarliestOf")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeEarliestOf(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ idsBytes: jbyteArray,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let data = readJByteArray(env: envPtr, array: idsBytes)
        guard !data.isEmpty,
              let ids = try? ScoreItemIDCodec.decodeArray(data)
        else { return env.pointee.NewByteArray(envPtr, 0) }
        let result = AudioMidiBridge.earliestOf(score: score, ids: ids)
        guard !result.isEmpty else { return env.pointee.NewByteArray(envPtr, 0) }
        return makeJByteArray(env: envPtr, bytes: result)
    }
#endif
