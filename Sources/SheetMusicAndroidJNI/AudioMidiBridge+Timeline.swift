import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicMIDI

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
/// `[totalTicks, totalSecondsMicros, division, totalUnrolledTicks]`, or an
/// empty array when the score handle is unknown. The trailing
/// `totalUnrolledTicks` is appended (existing indices unchanged) so the
/// Kotlin poll loop can detect end-of-score against the unrolled length.
public func nativeTimelineSummary(scoreHandle: Int64) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle) else { return [] }
    let summary = AudioMidiBridge.timelineSummary(score: score)
    return [
        summary.totalTicks, summary.totalSecondsMicros,
        summary.division, summary.totalUnrolledTicks,
    ]
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeFrameAtTick(...)` call site. Returns an empty
/// `Data` when the score handle is unknown or the tick has no frame.
public func nativeFrameAtTick(scoreHandle: Int64, tick: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.frameAtTick(score: score, tick: tick)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeSecondsAtTick(...)` call site.
///
/// Continuous seconds at a fractional UNROLLED player tick — the smooth
/// counterpart of `nativeFrameAtTick`, whose time snaps to a frame onset.
/// Returns **−1** for an unknown handle, which a real position never is;
/// returning 0 there would be indistinguishable from the start of the score.
public func nativeSecondsAtTick(scoreHandle: Int64, unrolledTick: Double) -> Double {
    guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
    return AudioMidiBridge.secondsAtTick(score: score, unrolledTick: unrolledTick)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeUnrolledTickForNotated(...)` call site: the
/// UNROLLED transport tick a NOTATED score tick sits at.
///
/// Returns **−1** for an unknown handle or a negative input, neither of which
/// a real scheduling target is; the Kotlin caller keeps its notated tick in
/// that case, which is exactly the old behavior and correct on any score
/// without a repeat.
public func nativeUnrolledTickForNotated(scoreHandle: Int64, notatedTick: Int64) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
    guard notatedTick >= 0 else { return -1 }
    return AudioMidiBridge.unrolledTickForNotated(score: score, notatedTick: notatedTick)
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

// MARK: - Carrying the transport across a score swap

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeSnapshotScore(...)` call site: a new handle holding a copy of the score behind
/// `scoreHandle` as it stands now, or 0 for an unknown handle.
///
/// The Android engine keeps one of the score it last prepared. Its host edits the score behind the prepared handle in
/// place, so when it adopts the edit (`replaceScore`) the score the cursor and the loop were measured against is gone
/// from that handle — and carrying them over (`nativeCarryCursor`, `nativeCarryLoop`) needs it. Released through
/// `nativeReleaseScore`, like any score handle. `Score` is a value, so the copy shares storage until the next edit.
public func nativeSnapshotScore(scoreHandle: Int64) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return 0 }
    return scoreTable.insert(score)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeCarryCursor(...)` call site: `cursorBytes`, a place in the score behind
/// `fromScoreHandle`, as the cursor at the same measure and offset in the score behind `toScoreHandle`
/// (`AudioMidiBridge.carriedCursor`). Empty `Data` for an unknown handle, an undecodable cursor, or one that names
/// nothing in the first score.
public func nativeCarryCursor(fromScoreHandle: Int64, toScoreHandle: Int64, cursorBytes: Data) -> Data {
    guard let old = scoreTable.value(for: fromScoreHandle),
          let new = scoreTable.value(for: toScoreHandle),
          !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes),
          let carried = AudioMidiBridge.carriedCursor(cursor, from: old, to: new)
    else { return Data() }
    return ScoreCursorCodec.encode(carried)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeCarryLoop(...)` call site: the loop `[startTick, endTick)` — NOTATED ticks of the score
/// behind `fromScoreHandle` — as the same measures and offsets in the score behind `toScoreHandle`
/// (`AudioMidiBridge.carriedLoop`). Answers `[start, end]`, or an empty array for an unknown handle, an empty range,
/// or a loop the edit left spanning nothing.
public func nativeCarryLoop(
    fromScoreHandle: Int64,
    toScoreHandle: Int64,
    startTick: Int64,
    endTick: Int64,
) -> [Int64] {
    guard let old = scoreTable.value(for: fromScoreHandle),
          let new = scoreTable.value(for: toScoreHandle),
          startTick >= 0, startTick < endTick,
          let carried = AudioMidiBridge.carriedLoop(
              LoopRange(startTick: Int(startTick), endTick: Int(endTick)), from: old, to: new,
          )
    else { return [] }
    return [Int64(carried.startTick), Int64(carried.endTick)]
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

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeInstrumentParams(...)` call site.
public func nativeInstrumentParams(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.instrumentParams(score: score)
}
