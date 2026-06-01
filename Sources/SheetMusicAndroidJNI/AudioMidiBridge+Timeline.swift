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

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeGMInstrumentList()` call site.
public func nativeGMInstrumentList() -> Data {
    GMInstrumentCodec.encodeAll()
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeBuildClickSoundFont(...)` call site. Reuses
/// the Phase 1 Core (`WavPcmReader` + `ClickSoundFontBuilder`) to turn two
/// click WAVs into a bank-128 SF2 mapping strong→note 76 / weak→note 77.
/// Returns empty `Data` on any read failure so the Kotlin caller can fall
/// back to the GM drum-kit.
public func nativeBuildClickSoundFont(strongWav: Data, weakWav: Data) -> Data {
    guard let strong = try? WavPcmReader.read(strongWav),
          let weak = try? WavPcmReader.read(weakWav)
    else { return Data() }
    return ClickSoundFontBuilder.build(
        strong: strong.samples, strongRate: strong.sampleRate,
        weak: weak.samples, weakRate: weak.sampleRate,
    )
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeItemEndTick(...)` call site. Returns -1 when
/// the score handle is unknown, the id payload is empty / undecodable, or
/// the timeline has no end-tick entry for the id (only `.note` / `.rest`
/// items are tracked).
public func nativeItemEndTick(scoreHandle: Int64, idBytes: Data) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
    guard !idBytes.isEmpty,
          let id = try? ScoreItemIDCodec.decode(idBytes)
    else { return -1 }
    return AudioMidiBridge.itemEndTick(score: score, id: id)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeTimelineSummary(...)` call site. Returns
/// `[totalTicks, totalSecondsMicros, division]`, or an empty array when
/// the score handle is unknown.
public func nativeTimelineSummary(scoreHandle: Int64) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle) else { return [] }
    let summary = AudioMidiBridge.timelineSummary(score: score)
    return [summary.totalTicks, summary.totalSecondsMicros, summary.division]
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeFrameAtTick(...)` call site. Returns an empty
/// `Data` when the score handle is unknown or the tick has no frame.
public func nativeFrameAtTick(scoreHandle: Int64, tick: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.frameAtTick(score: score, tick: tick)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeFrameForCursor(...)` call site. Returns an
/// empty `Data` when the score handle is unknown, the cursor payload is
/// empty / undecodable, or the timeline has no frame for the cursor.
public func nativeFrameForCursor(scoreHandle: Int64, cursorBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes)
    else { return Data() }
    return AudioMidiBridge.frameForCursor(score: score, cursor: cursor)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeMetronomeBeats(...)` call site.
public func nativeMetronomeBeats(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.metronomeBeats(score: score)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeStaffParams(...)` call site.
public func nativeStaffParams(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.staffParams(score: score)
}
