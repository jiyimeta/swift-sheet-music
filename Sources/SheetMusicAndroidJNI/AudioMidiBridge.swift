import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicMIDI

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePitchAndStaffOfNote(...)` call site.
/// Returns the sentinel `0xFFFF_FFFF_FFFF_FFFF` (-1 as Int64) when the
/// score handle is unknown or the note id no longer resolves.
public func nativePitchAndStaffOfNote(scoreHandle: Int64, noteIdBytes: Data) -> Int64 {
    let invalid = Int64(bitPattern: 0xFFFF_FFFF_FFFF_FFFF)
    guard let score = scoreTable.value(for: scoreHandle) else { return invalid }
    guard !noteIdBytes.isEmpty else { return invalid }
    guard let noteId = try? PathIDCodecs.decode(noteIdBytes) else { return invalid }
    return AudioMidiBridge.pitchAndStaffOfNote(score: score, noteId: noteId)
}

/// JNI entry point for `SheetMusicAudioJNI.nativePreviewRoute(...)`: where an audition of a note sounds —
/// `[pitch, staffIndex, channel, isDrum]`, routed through the instrument changes of the score behind
/// `preparedScoreHandle` (the engine's copy of the score it prepared) at the note's tick in the score behind
/// `scoreHandle`. A negative `pitch` sounds the note's own. An unknown `preparedScoreHandle` routes through the score
/// itself; empty when the score handle is unknown or the note does not resolve. See
/// `AudioMidiBridge.previewRoute(score:prepared:noteID:pitch:)`.
public func nativePreviewRoute(
    scoreHandle: Int64, preparedScoreHandle: Int64, noteIdBytes: Data, pitch: Int32,
) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle),
          !noteIdBytes.isEmpty,
          let noteID = try? PathIDCodecs.decode(noteIdBytes)
    else { return [] }
    let prepared = scoreTable.value(for: preparedScoreHandle) ?? score
    return AudioMidiBridge.previewRouteWire(score: score, prepared: prepared, noteID: noteID, pitch: Int(pitch))
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeEarliestOf(...)` call site. Returns an empty
/// `Data` when the score handle is unknown, the ids payload is empty /
/// undecodable, or the timeline reports no earliest item.
public func nativeEarliestOf(scoreHandle: Int64, idsBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard !idsBytes.isEmpty,
          let ids = try? ScoreItemIDCodec.decodeArray(idsBytes)
    else { return Data() }
    return AudioMidiBridge.earliestOf(score: score, ids: ids)
}
