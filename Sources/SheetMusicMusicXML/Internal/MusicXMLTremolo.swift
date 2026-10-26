import SheetMusicCore
import SheetMusicXMLTools

/// A note's `<notations><ornaments><tremolo>` as MuseScore's `addTremolo` reads it (`P2:6691-6777`): its marks
/// (1 to 4) and whether it is a tremolo on the note alone or one end of a two-note tremolo. An unmeasured tremolo —
/// a buzz roll, the only one MuseScore reads — is not modeled and reads as none.
enum MusicXMLTremolo: Equatable {
    case single(Tremolo.Subtype)
    /// The first note of a two-note tremolo, which waits for its stop.
    case start
    /// The second note of a two-note tremolo, whose marks count for the pair.
    case stop(Tremolo.Subtype)

    init?(note: XMLTreeNode) {
        let mark = note.all("notations").lazy.flatMap { $0.all("ornaments") }.flatMap { $0.all("tremolo") }.first
        guard let mark else { return nil }
        let marks = Int(mark.text) ?? 0
        guard let subtype = Tremolo.Subtype(rawValue: UInt8(clamping: marks)) else { return nil }
        switch mark.attributes["type"] ?? "" {
        case "", "single": self = .single(subtype)
        case "start": self = .start
        case "stop": self = .stop(subtype)
        default: return nil
        }
    }

    /// The note is one end of a two-note tremolo, whose time modification carries the tremolo's 2 — MuseScore takes
    /// it out of the ratio before making a tuplet of what is left (`addTremolo`: "timeMod takes into account also the
    /// factor 2 of a two-note tremolo").
    static func isTwoNote(_ note: XMLTreeNode) -> Bool {
        switch MusicXMLTremolo(note: note) {
        case .start, .stop: true
        default: false
        }
    }
}
