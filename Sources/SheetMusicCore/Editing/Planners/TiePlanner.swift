import Foundation

/// Finds the tie partner: the next chord (voice order, may cross the barline via `ElementNavigator`) containing a
/// note at the same pitch. Returns that note's `NoteID`, or `nil` when there is no such note — a caller uses `nil`
/// to decide that tying is unavailable from the source note.
public enum TiePlanner {
    public static func tieTarget(for noteID: NoteID, in score: Score) -> NoteID? {
        guard let source = score[noteID] else { return nil }
        guard let nextLocation = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score)
        else { return nil }
        guard case let .chord(nextChord)? = score[nextLocation], !nextChord.notes.isEmpty else { return nil }
        guard let matchIndex = nextChord.notes.firstIndex(where: { $0.pitch == source.pitch }) else { return nil }
        return NoteID(
            staff: nextLocation.staff,
            measureIndex: nextLocation.measureIndex,
            voiceIndex: nextLocation.voiceIndex,
            elementIndex: nextLocation.elementIndex,
            noteIndexInChord: matchIndex,
        )
    }
}
