import Foundation
import SheetMusicCore
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

        // Markers attached to glyph children of <direction-type>. The `kind`
        // is derived from the `<sound>` label when present so MSCX's
        // MuseScore-specific variants ("codab", "varcoda") are preserved as
        // `.other` rather than collapsing to `.coda`.
        if directionType.children.contains(where: { $0.name == "segno" }) {
            let label = sound?.attributes["segno"] ?? "segno"
            result.markers.append(Marker(
                kind: Marker.Kind(rawValue: label) ?? .other,
                label: label,
                text: "",
            ))
        }
        if directionType.children.contains(where: { $0.name == "coda" }) {
            let label = sound?.attributes["coda"] ?? "coda"
            result.markers.append(Marker(
                kind: Marker.Kind(rawValue: label) ?? .other,
                label: label,
                text: "",
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

    // MARK: - sound-driven classifiers

    private static func jump(forSound sound: XMLTreeNode, words: String) -> Jump? {
        if let segno = sound.attributes["dalsegno"] {
            return Jump(
                jumpTo: segno,
                playUntil: sound.attributes["tocoda"] ?? (sound.attributes["fine"] != nil ? "end" : "end"),
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
        // MuseScore stores "To Coda" as `<markerType>coda</markerType>` with
        // the text distinguishing it from plain-coda variants (`codab` etc.).
        // Match that mapping so semantic comparison passes.
        return Marker(
            kind: .coda,
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
