import Foundation
import SheetMusicAudioCore
import SheetMusicCore

// MARK: - T15: Timeline summary

extension AudioMidiBridge {
    struct TimelineSummary: Equatable {
        let totalTicks: Int64
        let totalSecondsMicros: Int64
        let division: Int64
    }

    static func timelineSummary(score: Score) -> TimelineSummary {
        let t = PlaybackTimeline(score: score)
        return TimelineSummary(
            totalTicks: Int64(t.totalTicks),
            totalSecondsMicros: Int64((t.totalSeconds * 1_000_000).rounded()),
            division: Int64(t.division),
        )
    }
}

#if os(Android)
    import CJNI

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeTimelineSummary")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeTimelineSummary(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
    ) -> jlongArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewLongArray(envPtr, 0)
        }
        let summary = AudioMidiBridge.timelineSummary(score: score)
        var values: [Int64] = [
            summary.totalTicks,
            summary.totalSecondsMicros,
            summary.division,
        ]
        let array = env.pointee.NewLongArray(envPtr, 3)
        values.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            env.pointee.SetLongArrayRegion(envPtr, array, 0, 3, base)
        }
        return array
    }
#endif
