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
