import SheetMusicFoundation
import SheetMusicXMLTools

/// The one repeat MuseScore makes of a `<direction>` (`MusicXmlParserDirection::handleRepeats`,
/// `importmusicxmlpass2.cpp:~4655-4676`). A coda or segno carries its `<sound>` label when it has one; a To Coda and a
/// D.S. carry the `<sound>` value naming their target.
enum MusicXMLRepeat: Sendable, Equatable {
    case coda(String?)
    case segno(String?)
    case fine
    case toCoda(String)
    case daCapo
    case dalSegno(String)
}

/// Picks a direction's one repeat: the first `<sound>` attribute present among `coda`, `dacapo`, `dalsegno`, `fine`,
/// `segno`, `tocoda`, in that order, else the `<segno/>` / `<coda/>` glyph the direction-type carries.
enum MusicXMLRepeatClassifier {
    /// `sound` is the direction's last `<sound>` (each one sets every attribute again, `P2:4115-4122`); an attribute
    /// counts when it is present and not empty, as MuseScore reads an absent one as empty. `glyphs` are the
    /// direction-type's `segno` / `coda` element names in document order. Without a `<sound>` repeat a glyph decides,
    /// one family only: with both a segno and a coda MuseScore's words match no repeat (`matchRepeat`,
    /// `P2:4324-4368`). Text-type inference gates none of it.
    static func classify(sound: XMLTreeNode?, glyphs: [String]) -> MusicXMLRepeat? {
        let attributes = sound?.attributes ?? [:]
        func value(_ name: String) -> String? {
            guard let text = attributes[name], !text.isEmpty else { return nil }
            return text
        }
        if let label = value("coda") { return .coda(label) }
        if value("dacapo") != nil { return .daCapo }
        if let target = value("dalsegno") { return .dalSegno(target) }
        if value("fine") != nil { return .fine }
        if let label = value("segno") { return .segno(label) }
        if let target = value("tocoda") { return .toCoda(target) }
        let hasCoda = glyphs.contains("coda")
        let hasSegno = glyphs.contains("segno")
        if hasCoda, !hasSegno { return .coda(nil) }
        if hasSegno, !hasCoda { return .segno(nil) }
        return nil
    }

    /// The direction's repeat, read from its last `<sound>` and its glyphs.
    static func classify(_ direction: XMLTreeNode, source: MusicXMLRepeatSource) -> MusicXMLRepeat? {
        classify(sound: direction.all("sound").last, glyphs: source.glyphs)
    }
}

/// What a repeat direction's text is made of — MuseScore's `m_wordsText` as `directionType` builds it
/// (`P2:4037-4092`): each `<words>` as xml text and each `<segno>` / `<coda>` as its `<sym>`, in document order.
struct MusicXMLRepeatSource: Sendable, Equatable {
    /// The words and glyph symbols as xml text.
    var xmlText = ""
    /// The direction has a `<words>`.
    var hasWords = false
    /// The first `<words>`' trimmed characters, which a jump prints.
    var firstWords = ""
    /// The `segno` / `coda` glyphs' element names, in document order.
    var glyphs: [String] = []
    /// The first `<segno>`'s and the first `<coda>`'s `smufl` attribute.
    var segnoSmufl: String?
    var codaSmufl: String?
    /// `print-object != "no"` on the last `<direction-type>` child (`m_visible`, `P2:4023`).
    var visible = true

    init(_ direction: XMLTreeNode) {
        for type in direction.all("direction-type") {
            for child in type.children {
                visible = child.attributes["print-object"] != "no"
                read(child)
            }
        }
    }

    private mutating func read(_ child: XMLTreeNode) {
        switch child.name {
        case "words":
            if !hasWords { firstWords = child.text }
            hasWords = true
            xmlText += MusicXMLFormattedWords.xmlText(of: child)
        case "segno", "coda":
            let smufl = child.attributes["smufl"].flatMap { $0.isEmpty ? nil : $0 }
            if child.name == "segno", !glyphs.contains("segno") { segnoSmufl = smufl }
            if child.name == "coda", !glyphs.contains("coda") { codaSmufl = smufl }
            glyphs.append(child.name)
            xmlText += "<sym>\(smufl ?? child.name)</sym>"
        default:
            break
        }
    }
}
