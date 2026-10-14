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
/// MuseScore's MSCX model splits these into `<Marker>` (measure-left) and
/// `<Jump>` (measure-right), which this decoder mirrors.
enum MusicXMLJumpDecoder {
    struct Decoded {
        var markers: [Marker] = []
        var jumps: [Jump] = []
    }

    /// Decode a single `<direction>` element. Returns empty decoded on a
    /// plain text direction that isn't navigation-related.
    static func decode(_ direction: XMLTreeNode) -> Decoded {
        var result = Decoded()
        guard let directionType = direction.first("direction-type") else { return result }
        let sound = direction.first("sound")

        // A `<segno/>` or `<coda/>`: the glyph names the family, the `<sound>` label the member.
        if let glyph = directionType.first("segno") {
            result.markers.append(glyphMarker(
                family: .segno, label: sound?.attributes["segno"], smufl: glyph.attributes["smufl"],
            ))
        }
        if let glyph = directionType.first("coda") {
            result.markers.append(glyphMarker(
                family: .coda, label: sound?.attributes["coda"], smufl: glyph.attributes["smufl"],
            ))
        }

        // Word-based navigation ("To Coda", "D.C.", "D.S.", "Fine"): use
        // <sound> hints as the authoritative signal; the <words> body is
        // carried over for display text.
        let words = directionType.first("words")?.text ?? ""
        if let sound, let jump = jump(forSound: sound, words: words) {
            result.jumps.append(jump)
        }
        if let sound, let toCoda = toCodaMarker(forSound: sound, words: words) {
            result.markers.append(toCoda)
        }
        if let sound, let fine = fineMarker(forSound: sound, words: words) {
            result.markers.append(fine)
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

    // MARK: - sound-driven classifiers

    private static func jump(forSound sound: XMLTreeNode, words: String) -> Jump? {
        if let segno = sound.attributes["dalsegno"] {
            return Jump(
                jumpTo: segno,
                playUntil: sound.attributes["tocoda"] ?? (sound.attributes["fine"] != nil ? "fine" : "end"),
                continueAt: sound.attributes["coda"] ?? "",
                text: words.isEmpty ? "D.S." : words,
            )
        }
        if sound.attributes["dacapo"] != nil {
            return Jump(
                jumpTo: "start",
                playUntil: sound.attributes["tocoda"] ?? (sound.attributes["fine"] != nil ? "fine" : "end"),
                continueAt: sound.attributes["coda"] ?? "",
                text: words.isEmpty ? "D.C." : words,
            )
        }
        return nil
    }

    private static func toCodaMarker(forSound sound: XMLTreeNode, words: String) -> Marker? {
        guard sound.attributes["tocoda"] != nil else { return nil }
        // MuseScore's To Coda (`importmusicxmlpass2.cpp:4790-4794`).
        return Marker(
            kind: .toCoda,
            label: sound.attributes["tocoda"] ?? "coda",
            text: words.isEmpty ? "To Coda" : words,
        )
    }

    private static func fineMarker(forSound sound: XMLTreeNode, words: String) -> Marker? {
        guard sound.attributes["fine"] != nil else { return nil }
        return Marker(
            kind: .fine,
            label: "fine",
            text: words.isEmpty ? "Fine" : words,
        )
    }
}
