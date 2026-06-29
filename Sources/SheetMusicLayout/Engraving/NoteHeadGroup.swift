/// Notehead group enum mapping MS4 `<head>` tokens to SMuFL glyph-name tables.
///
/// C++: src/engraving/dom/note.cpp:89-322,
///      src/engraving/types/typesconv.cpp:1145-1235
public enum NoteHeadGroup: String, CaseIterable, Sendable {
    // Basic noteheads
    case normal
    case cross
    case plus
    case xcircle
    case withX = "withx"
    case triangleUp = "triangle-up"
    case triangleDown = "triangle-down"
    case slashed1
    case slashed2
    case diamond
    case diamondOld = "diamond-old"
    case circled
    case circledLarge = "circled-large"
    case largeArrow = "large-arrow"
    case brevisAlt = "altbrevis"
    // Slash / large-diamond
    case slash
    case largeDiamond = "large-diamond"
    // Heavy cross
    case heavyCross = "heavy-cross"
    case heavyCrossHat = "heavy-cross-hat"
    // Shape notes (Southern Harmony / Sacred Harp)
    case sol
    case la
    case fa
    case mi
    case doShape = "do"
    case reShape = "re"
    case tiShape = "ti"
    // Walker shape notes
    case doWalker = "do-walker"
    case reWalker = "re-walker"
    case tiWalker = "ti-walker"
    // Funk shape notes
    case doFunk = "do-funk"
    case reFunk = "re-funk"
    case tiFunk = "ti-funk"
    // Named-solfège noteheads
    case doName = "do-name"
    case diName = "di-name"
    case raName = "ra-name"
    case reName = "re-name"
    case riName = "ri-name"
    case meName = "me-name"
    case miName = "mi-name"
    case faName = "fa-name"
    case fiName = "fi-name"
    case seName = "se-name"
    case solName = "sol-name"
    case leName = "le-name"
    case laName = "la-name"
    case liName = "li-name"
    case teName = "te-name"
    case tiName = "ti-name"
    case siName = "si-name"
    // Named-pitch noteheads
    case aSharpName = "a-sharp-name"
    case aName = "a-name"
    case aFlatName = "a-flat-name"
    case bSharpName = "b-sharp-name"
    case bName = "b-name"
    case bFlatName = "b-flat-name"
    case cSharpName = "c-sharp-name"
    case cName = "c-name"
    case cFlatName = "c-flat-name"
    case dSharpName = "d-sharp-name"
    case dName = "d-name"
    case dFlatName = "d-flat-name"
    case eSharpName = "e-sharp-name"
    case eName = "e-name"
    case eFlatName = "e-flat-name"
    case fSharpName = "f-sharp-name"
    case fName = "f-name"
    case fFlatName = "f-flat-name"
    case gSharpName = "g-sharp-name"
    case gName = "g-name"
    case gFlatName = "g-flat-name"
    case hName = "h-name"
    case hSharpName = "h-sharp-name"
    // Swiss rudiments
    case swissRudimentsFlam = "swiss-rudiments-flam"
    case swissRudimentsDouble = "swiss-rudiments-double"

    /// Resolve a MS4 `<head>` token to a group.
    /// Returns `nil` for unknown tokens and for `"custom"` (HEAD_CUSTOM).
    public static func from(token: String) -> NoteHeadGroup? {
        guard token != "custom" else { return nil }
        return NoteHeadGroup(rawValue: token)
    }

    /// Look up the SMuFL SymId name for a given group, kind, and stem direction.
    /// Returns `"noSym"` for absent cells (e.g. named noteheads have no doubleWhole).
    public static func symName(group: NoteHeadGroup, kind: NoteHeadKind, stemUp: Bool) -> String {
        let table = stemUp ? upStemTable : downStemTable
        guard let row = table[group] else { return "noSym" }
        return row[kind.tableIndex]
    }
}

/// Duration-category of a notehead for glyph-table lookup.
public enum NoteHeadKind: Sendable {
    case whole
    case half
    case quarter
    case doubleWhole

    var tableIndex: Int {
        switch self {
        case .whole: return 0
        case .half: return 1
        case .quarter: return 2
        case .doubleWhole: return 3
        }
    }
}
