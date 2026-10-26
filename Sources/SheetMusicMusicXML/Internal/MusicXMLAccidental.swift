import SheetMusicCore
import SheetMusicXMLTools

/// A note's `<accidental>` as MuseScore's import reads it (`accidental`, `importmusicxmlnotepitch.cpp:49-86`): the
/// symbol its text names (`musicXmlString2accidentalType`, `musicxmlsupport.cpp:512-575`), `user` when it is
/// cautionary or editorial, and in parentheses or brackets as its attributes ask. Its color and cue size are not
/// modeled.
struct MusicXMLAccidental: Equatable {
    let accidental: Accidental
    let bracket: AccidentalBracket
    let role: AccidentalRole

    /// Nil for a note with no `<accidental>`, or one whose text names no symbol MuseScore reads.
    init?(note: XMLTreeNode) {
        guard let node = note.first("accidental"),
              let accidental = Self.symbol(node.text, smufl: node.attributes["smufl"])
        else { return nil }
        self.accidental = accidental
        let cautionary = node.attributes["cautionary"] == "yes"
        let editorial = node.attributes["editorial"] == "yes"
        // MuseScore cannot tell a cautionary accidental from an editorial one, except by the brackets each implies.
        role = cautionary || editorial ? .user : .auto
        if node.attributes["parentheses"] == "no" || node.attributes["bracket"] == "no" {
            bracket = .none
        } else if node.attributes["parentheses"] == "yes" || cautionary {
            bracket = .parenthesis
        } else if node.attributes["bracket"] == "yes" || editorial {
            bracket = .bracket
        } else {
            bracket = .none
        }
    }

    /// MuseScore's microtonal accidentals (`Accidental::isMicrotonal`): every type past the triple flat, which its
    /// import always keeps as `user` (`markUserAccidentals`).
    static let microtonal = Set(Accidental.allCases.drop { $0 != .tripleFlat }.dropFirst())

    /// The symbol a MusicXML accidental name stands for; `other` names one by its SMuFL glyph, from the arrow,
    /// Helmholtz-Ellis comma and equal-tempered sets MuseScore reads (`smuflAccidentalTypes`).
    static func symbol(_ name: String, smufl: String?) -> Accidental? {
        if let named = byName[name] { return named }
        guard name == "other", let smufl, let glyph = Accidental(rawValue: smufl), byGlyph.contains(glyph)
        else { return nil }
        return glyph
    }

    /// `musicXmlString2accidentalType`'s table, entry for entry: `natural-sharp` and `natural-flat` are read as the
    /// plain sharp and flat.
    private static let byName: [String: Accidental] = [
        "sharp": .sharp, "natural": .natural, "flat": .flat,
        "double-sharp": .doubleSharp, "sharp-sharp": .doubleSharp, "flat-flat": .doubleFlat,
        "natural-sharp": .sharp, "natural-flat": .flat,
        "quarter-flat": .mirroredFlat, "quarter-sharp": .sharpSlash,
        "three-quarters-flat": .mirroredFlat2, "three-quarters-sharp": .sharpSlash4,
        "sharp-up": .sharpArrowUp, "natural-down": .naturalArrowDown, "natural-up": .naturalArrowUp,
        "sharp-down": .sharpArrowDown, "flat-down": .flatArrowDown, "flat-up": .flatArrowUp,
        "double-sharp-down": .sharp2ArrowDown, "double-sharp-up": .sharp2ArrowUp,
        "flat-flat-down": .flat2ArrowDown, "flat-flat-up": .flat2ArrowUp,
        "arrow-down": .arrowDown, "arrow-up": .arrowUp,
        "triple-sharp": .tripleSharp, "triple-flat": .tripleFlat,
        "slash-quarter-sharp": .sharpSlash3, "slash-sharp": .sharpSlash2,
        "slash-flat": .flatSlash, "double-slash-flat": .flatSlash2,
        "sharp-1": .oneCommaSharp, "sharp-2": .twoCommaSharp, "sharp-3": .threeCommaSharp, "sharp-5": .fiveCommaSharp,
        "flat-1": .oneCommaFlat, "flat-2": .twoCommaFlat, "flat-3": .threeCommaFlat, "flat-4": .fourCommaFlat,
        "sori": .sori, "koron": .koron,
    ]

    /// `smuflAccidentalTypes`: the one-, two- and three-arrow accidentals through the equal-tempered ones, which run
    /// unbroken in both enums. A case's raw value is its SMuFL name.
    static let byGlyph: Set<Accidental> = {
        let all = Accidental.allCases
        guard let first = all.firstIndex(of: .doubleFlatOneArrowDown),
              let last = all.firstIndex(of: .quarterSharpEqualTempered)
        else { return [] }
        return Set(all[first ... last])
    }()
}
