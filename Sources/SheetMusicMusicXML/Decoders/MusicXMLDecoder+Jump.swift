import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decodes MusicXML `<direction>` entries that carry jumps and markers.
///
/// MusicXML encodes navigation via two cooperating structures:
/// 1. A **visible glyph** inside `<direction-type>`: `<segno/>`, `<coda/>`,
///    or `<words>` matching one of "To Coda", "D.C.", "D.S.", "Fine", etc.
/// 2. A **sound hint** inside the same `<direction>`: `<sound dalsegno="…"/>`,
///    `<sound dacapo="yes"/>`, `<sound tocoda="…"/>`, `<sound coda="…"/>`,
///    `<sound segno="…"/>`, `<sound fine="yes"/>`.
///
/// A direction makes ONE repeat, the one `MusicXMLRepeatClassifier` picks (`handleRepeats`,
/// `importmusicxmlpass2.cpp:~4652-4773`): a `<Marker>` or a `<Jump>`, as MuseScore's MSCX model splits them.
enum MusicXMLJumpDecoder {
    struct Decoded {
        var markers: [Marker] = []
        var jumps: [Jump] = []
        /// When the direction made a segno: its words and glyphs as xml text (MuseScore's `m_wordsText`), which a
        /// second segno at the same tick merges with (`P2:~4718-4730`).
        var segnoWords: String?
    }

    /// Decode a single `<direction>` element. Returns empty decoded on a
    /// plain text direction that isn't navigation-related.
    static func decode(_ direction: XMLTreeNode) -> Decoded {
        var measureHasCoda = false
        return decode(direction, measureHasCoda: &measureHasCoda)
    }

    /// Decode a single `<direction>` element, given whether its bar already holds a coda or To Coda: a second one is
    /// discarded, and the first sets the flag (`handleRepeats`' `measureHasCoda`, `P2:~4712-4737`).
    static func decode(_ direction: XMLTreeNode, measureHasCoda: inout Bool) -> Decoded {
        let source = MusicXMLRepeatSource(direction)
        let sound = direction.all("sound").last
        var result = Decoded()
        guard let found = MusicXMLRepeatClassifier.classify(sound: sound, glyphs: source.glyphs) else { return result }
        switch found {
        case .coda, .toCoda:
            guard !measureHasCoda else { return result }
            measureHasCoda = true
        default:
            break
        }
        switch found {
        case let .coda(label):
            let marker = glyphMarker(family: .coda, label: label, smufl: source.codaSmufl)
            result.markers = [withText(marker, glyphIsKind: true, source: source)]
        case let .segno(label):
            let marker = glyphMarker(family: .segno, label: label, smufl: source.segnoSmufl)
            result.markers = [withText(marker, glyphIsKind: true, source: source)]
            result.segnoWords = source.xmlText
        case .fine:
            result.markers = [withText(Marker(kind: .fine, label: "fine"), glyphIsKind: false, source: source)]
        case let .toCoda(target):
            result.markers = [withText(Marker(kind: .toCoda, label: target), glyphIsKind: false, source: source)]
        case .daCapo:
            result.jumps = [jump(to: "start", fallback: "D.C.", sound: sound, source: source)]
        case let .dalSegno(target):
            result.jumps = [jump(to: target, fallback: "D.S.", sound: sound, source: source)]
        }
        return result
    }

    /// A segno or coda glyph's marker. MuseScore's importer always makes a plain SEGNO or CODA of it
    /// (`MusicXmlParserDirection::handleRepeats`, `importmusicxmlpass2.cpp:~4659-4670`); the variants are a DELIBERATE
    /// EXTENSION with no oracle, there so MuseScore's own exports round-trip: its exporter writes the variant's glyph
    /// as `smufl="segnoSerpent1"` / `"codaSquare"` on the `<segno>` / `<coda>` and the marker's label as the `<sound>`
    /// value (`exportmusicxml.cpp:~6179-6239`). The `smufl` attribute is preferred; else the `<sound>` label names the
    /// member (`varsegno`; `varcoda`, `codetta`); else the family's plain kind. The label defaults to that kind's.
    private static func glyphMarker(family: Marker.Kind, label: String?, smufl: String?) -> Marker {
        let members: [Marker.Kind] = family == .segno ? [.segno, .varsegno] : [.coda, .varcoda, .codetta]
        let fromGlyph: Marker.Kind? = switch smufl {
        case "segnoSerpent1": .varsegno
        case "codaSquare": .varcoda
        default: nil
        }
        let named = label.flatMap { Marker.Kind(mscxName: $0) }
        let kind = fromGlyph.flatMap { members.contains($0) ? $0 : nil }
            ?? named.flatMap { members.contains($0) ? $0 : nil } ?? family
        return Marker(kind: kind, label: label ?? kind.defaultLabel, text: "")
    }

    /// The marker with the direction's text and visibility. Words are the marker's text (plain, with the markup while
    /// it is formatted) even when they equal the kind's default. A direction with only a glyph keeps no text of its
    /// own when the glyph is the marker's own symbol (a coda or segno made of it, `glyphIsKind`) or the kind's
    /// default; otherwise it stores the glyph (a To Coda made of a lone `<coda/>` prints the coda sign, as in
    /// MuseScore). A direction with no text at all keeps the kind's default and stays visible: MuseScore hides it
    /// (`setVisible(false)`) and then sets the direction's own visibility over that (`tb->setVisible(m_visible)`,
    /// `P2:~4743-4769`).
    private static func withText(_ marker: Marker, glyphIsKind: Bool, source: MusicXMLRepeatSource) -> Marker {
        var result = marker
        result.elementProperties.visible = source.visible
        guard !source.xmlText.isEmpty else { return result }
        if !source.hasWords, glyphIsKind || source.xmlText == marker.kind.defaultXMLText { return result }
        let carrier = MusicXMLFormattedWords.carrier(fromXMLText: source.xmlText)
        result.text = carrier.plain
        result.preservedTextMarkup = carrier.markup
        return result
    }

    /// A D.C. or D.S.: the `<sound>`'s other attributes steer it — `tocoda` or `fine` is where it plays until, `coda`
    /// where it continues — and make no marker of their own. It prints its first words, else its abbreviation.
    private static func jump(
        to target: String, fallback: String, sound: XMLTreeNode?, source: MusicXMLRepeatSource,
    ) -> Jump {
        let attributes = sound?.attributes ?? [:]
        var jump = Jump(
            jumpTo: target,
            playUntil: attributes["tocoda"] ?? (attributes["fine"] != nil ? "fine" : "end"),
            continueAt: attributes["coda"] ?? "",
            text: source.firstWords.isEmpty ? fallback : source.firstWords,
        )
        jump.elementProperties.visible = source.visible
        return jump
    }
}
