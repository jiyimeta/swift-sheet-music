import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

// Host-testable bridge helpers + Android-only @_cdecl entry point for
// resolving an `AudioExportRange` (encoded by Kotlin) into a half-open
// `[startTick, endTick)` range against a score's `PlaybackTimeline`.

extension AudioMidiBridge {
    /// Resolve the encoded range payload against the score's timeline.
    ///
    /// Returns `(-1, -1)` on any failure (unknown tag, version mismatch,
    /// unresolvable cursor, empty range). `.currentLoop` falls back to
    /// `.full` semantics here because the engine's loop state lives on
    /// the Kotlin side; the host resolves `.currentLoop` itself before
    /// calling into JNI.
    static func resolveExportTickRange(
        score: Score, rangePayload: Data,
    ) -> (start: Int64, end: Int64) {
        do {
            let range = try AudioExportRangeCodec.decode(rangePayload)
            let timeline = PlaybackTimeline(score: score)
            let resolved = try range.resolveTickRange(timeline: timeline, loop: nil)
            return (Int64(resolved.startTick), Int64(resolved.endTick))
        } catch {
            return (-1, -1)
        }
    }
}

#if os(Android)
    import CJNI

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeResolveExportTickRange")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeResolveExportTickRange(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ rangeBytes: jbyteArray,
    ) -> jlongArray? {
        guard envPtr.pointee != nil else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return makeResolveResultArray(envPtr: envPtr, start: -1, end: -1)
        }
        let data = readJByteArray(env: envPtr, array: rangeBytes)
        guard !data.isEmpty else {
            return makeResolveResultArray(envPtr: envPtr, start: -1, end: -1)
        }
        let (start, end) = AudioMidiBridge.resolveExportTickRange(
            score: score, rangePayload: data,
        )
        return makeResolveResultArray(envPtr: envPtr, start: start, end: end)
    }

    private func makeResolveResultArray(
        envPtr: UnsafeMutablePointer<JNIEnv?>, start: Int64, end: Int64,
    ) -> jlongArray? {
        guard let env = envPtr.pointee else { return nil }
        let array = env.pointee.NewLongArray(envPtr, 2)
        var values: [jlong] = [jlong(start), jlong(end)]
        values.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            env.pointee.SetLongArrayRegion(envPtr, array, 0, 2, base)
        }
        return array
    }
#endif
