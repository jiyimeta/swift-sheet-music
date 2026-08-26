import SheetMusicCore
import SheetMusicFoundation

/// Tracks the current `<divisions>` value within a part as MusicXML is walked.
/// MusicXML encodes intra-measure positions and durations as an integer number
/// of divisions, where "1 quarter note = N divisions" for some N redeclared by
/// `<attributes><divisions>`. This context converts those integers to
/// `Fraction`-of-a-whole-note, which `NoteDuration.fraction` can represent.
struct DivisionsContext {
    /// Ticks per quarter note in the currently-active `<attributes>`.
    var perQuarter: Int

    init(perQuarter: Int = 480) {
        self.perQuarter = perQuarter
    }

    /// Convert a MusicXML `<duration>` integer to a Fraction of a whole note.
    /// A quarter note is `perQuarter` divisions, and a whole note is `4 * perQuarter`.
    func fractionOfWhole(_ duration: Int) -> Fraction {
        Fraction(numerator: duration, denominator: 4 * perQuarter)
    }
}
