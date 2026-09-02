import SheetMusicFoundation

/// The visual barline subtypes an edit can write, spelled as MuseScore's MSCX `<BarLine><subtype>` tokens
/// (`typesconv.cpp`, `BarLineType`). Repeats are not here: `<startRepeat>` / `<endRepeat>` are measure flags in
/// the file format and the layout generates their barlines — see `SetRepeatBarLines`.
public enum BarLineStyle: String, Sendable, CaseIterable {
    case normal
    case double
    case end
    case dashed
    case dotted
    case heavy
    case doubleHeavy = "double-heavy"
}
