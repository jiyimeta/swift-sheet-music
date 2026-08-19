import SheetMusicCore
import SheetMusicFoundation

/// MuseScore's `Location::note` — the `<notes>` half of a
/// `<location>`, identifying *which* note of a chord a connector
/// endpoint refers to.
///
/// `Location::note` (`dom/location.cpp:214-231`) returns `0` when the
/// chord holds a single note, and otherwise the note's index within
/// `Chord::notes()`. That vector is kept sorted ascending by pitch —
/// `Chord::add` (`dom/chord.cpp:626-650`) inserts each note ahead of
/// the first one whose pitch is not lower — so the index is the note's
/// **rank by pitch**, independent of the order the `<Note>` elements
/// happen to appear in the file. This project's `ChordNotes` preserves
/// insertion order instead, so the rank is computed here rather than
/// read off the array. MuseScore's secondary sort on `Note::line` can
/// never fire for us: it only breaks ties between equal pitches, which
/// `ChordNotes` forbids by construction.
enum MSCXLocationNoteIndex {
    static func index(ofPitch pitch: Int, in notes: ChordNotes) -> Int {
        guard notes.count > 1 else { return 0 }
        return notes.reduce(into: 0) { rank, note in
            if note.pitch < pitch { rank += 1 }
        }
    }
}
