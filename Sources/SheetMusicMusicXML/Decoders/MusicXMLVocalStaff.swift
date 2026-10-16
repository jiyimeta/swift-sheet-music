import SheetMusicXMLTools

/// MuseScore's vocal-staff test (`MusicXmlPart::isVocalStaff`, `musicxmlpart.cpp:224-227`): the part's name is exactly
/// one of the voice names (`vocalInstrumentNames`, `musicxmlpart.cpp:33-43`). The name is `<part-name>`, replaced by
/// `<part-name-display>`'s `<display-text>` when that is not empty (`P1:2426-2448`). A hairpin's side defaults to
/// above on a vocal staff, below on any other (`P2:3818-3824`, `4575-4578`).
enum MusicXMLVocalStaff {
    private static let names: Set = [
        "Voice", "Soprano", "Mezzo-Soprano", "Alto", "Tenor", "Baritone", "Bass", "Women", "Men",
    ]

    static func isVocal(scorePart: XMLTreeNode) -> Bool {
        names.contains(name(of: scorePart))
    }

    /// The part's name as MuseScore's pass 1 sets it. An `<accidental-text>` in the display adds its glyph, which no
    /// voice name holds, so it is read as a character that keeps the name from matching.
    static func name(of scorePart: XMLTreeNode) -> String {
        var name = scorePart.first("part-name")?.text ?? ""
        for display in scorePart.all("part-name-display") {
            var shown = ""
            for child in display.children {
                switch child.name {
                case "display-text": shown += child.text
                case "accidental-text": shown += "\u{266E}"
                default: break
                }
            }
            if !shown.isEmpty { name = shown }
        }
        return name
    }
}
