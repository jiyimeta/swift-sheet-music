import SheetMusicCore

/// The engraving element sitting under a point during a hit-test.
///
/// `ScoreHitTester.hitTest(at:)` returns one of these. The library
/// does not dictate what a click "means" — it just reports what was
/// hit, so the app can decide its own selection / interaction policy
/// (MuseScore-style beam-length editing, "clicking the stem selects
/// the note", "clicking the beam selects the run", etc.).
///
/// For `.stem`, `.flag`, and `.beam`, the associated `notes` array
/// lists every notehead that shares the stem / flag / beam run. For
/// a chord this is all of its notes; for a beam run it is every
/// notehead on every chord under that beam.
public enum ScoreHitTarget: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case stem(notes: [NoteID])
    case flag(notes: [NoteID])
    case beam(notes: [NoteID])
}
