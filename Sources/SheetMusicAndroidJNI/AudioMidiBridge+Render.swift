import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicMIDI

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

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderMetronomeMidi(...)` call site. Returns an
/// empty `Data` when the score handle is unknown or rendering throws — the
/// engine then simply runs without a metronome player.
public func nativeRenderMetronomeMidi(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard let bytes = try? AudioMidiBridge.renderMetronomeMidi(score: score) else {
        return Data()
    }
    return bytes
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderCountInMetronomeMidi(...)` call site: the metronome sequence with a
/// count-in in front, for playback starting at `fromCursorBytes` (whose unrolled tick the caller passes as
/// `baseTick`). Empty `Data` when the handle is unknown, the position has no count-in, or rendering throws.
public func nativeRenderCountInMetronomeMidi(
    scoreHandle: Int64, fromCursorBytes: Data, baseTick: Int64,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    let cursor = try? ScoreCursorCodec.decode(fromCursorBytes)
    guard let bytes = try? AudioMidiBridge.renderCountInMetronomeMidi(
        score: score, cursor: cursor, baseTick: Int(baseTick),
    ) else {
        return Data()
    }
    return bytes
}
