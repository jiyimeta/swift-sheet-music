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

// MARK: - T17: Metronome beats + staff params

extension AudioMidiBridge {
    static func metronomeBeats(score: Score) -> Data {
        let beats = PlaybackTimeline.metronomeBeats(score: score)
        return MetronomeBeatCodec.encodeArray(beats)
    }

    static func staffParams(score: Score) -> Data {
        let entries = score.allStaves.enumerated().map { idx, entry -> StaffParams in
            let part = score.part(at: entry.address)
            let channel = part?.instrument.channels.first ?? InstrumentChannel()
            return StaffParams(
                staffIndex: idx,
                bankLSB: UInt8(clamping: channel.bank),
                program: UInt8(clamping: channel.program),
                isDrums: part?.instrument.useDrumset == true,
                partAddressHash: Int64(entry.address.partIndex) * 1000
                    + Int64(entry.address.staffIndexInPart),
            )
        }
        return StaffParamsCodec.encodeArray(entries)
    }
}

// MARK: - T16: Frame lookup

extension AudioMidiBridge {
    static func frameAtTick(score: Score, tick: Int64) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(atTick: Int(tick)) else { return Data() }
        return FrameCodec.encode(frame)
    }

    static func frameForCursor(score: Score, cursor: ScoreCursor) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(forCursor: cursor) else { return Data() }
        return FrameCodec.encode(frame)
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

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameAtTick")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameAtTick(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ tick: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let data = AudioMidiBridge.frameAtTick(score: score, tick: tick)
        guard !data.isEmpty else { return env.pointee.NewByteArray(envPtr, 0) }
        return makeJByteArray(env: envPtr, bytes: data)
    }

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameForCursor")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeFrameForCursor(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ cursorBytes: jbyteArray,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let cursorData = readJByteArray(env: envPtr, array: cursorBytes)
        guard !cursorData.isEmpty,
              let cursor = try? ScoreCursorCodec.decode(cursorData)
        else { return env.pointee.NewByteArray(envPtr, 0) }
        let data = AudioMidiBridge.frameForCursor(score: score, cursor: cursor)
        guard !data.isEmpty else { return env.pointee.NewByteArray(envPtr, 0) }
        return makeJByteArray(env: envPtr, bytes: data)
    }

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeMetronomeBeats")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeMetronomeBeats(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let data = AudioMidiBridge.metronomeBeats(score: score)
        return makeJByteArray(env: envPtr, bytes: data)
    }

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeStaffParams")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeStaffParams(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let data = AudioMidiBridge.staffParams(score: score)
        return makeJByteArray(env: envPtr, bytes: data)
    }

    @_cdecl("Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeItemEndTick")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeItemEndTick(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ idBytes: jbyteArray,
    ) -> jlong {
        guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
        let data = readJByteArray(env: envPtr, array: idBytes)
        guard !data.isEmpty,
              let id = try? ScoreItemIDCodec.decode(data)
        else { return -1 }
        return AudioMidiBridge.itemEndTick(score: score, id: id)
    }
#endif
