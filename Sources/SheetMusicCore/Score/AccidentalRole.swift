import SheetMusicFoundation

/// Provenance of a note's accidental: did the engraver compute it
/// automatically, or did the user force it explicitly?
///
/// MuseScore hides an AUTO accidental once its alteration is already
/// in force on the staff line (from the key signature or an earlier
/// accidental in the same measure), but always keeps a USER accidental
/// — the user asked for it, so it stays even when "redundant" (a
/// courtesy / cautionary accidental). The redundant-accidental
/// suppression pass (`Score.suppressingRedundantAccidentals()`)
/// branches on this flag.
///
/// MuseScore writes `<Accidental><role>1</role>` only for USER
/// accidentals; an absent `<role>` means AUTO.
///
/// C++: `mu::engraving::AccidentalRole` (`src/engraving/dom/accidental.h`).
public enum AccidentalRole: Int, Sendable {
    /// Computed by the engraver from pitch + context. C++: `AUTO`.
    case auto = 0
    /// Explicitly placed / forced by the user. C++: `USER`.
    case user = 1
}
