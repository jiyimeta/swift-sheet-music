import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

// MARK: - Fingerings

/// MusicXML encodes fingerings under `<notations><technical><fingering>`.
///
/// The spec (3.1 `fingering`) allows several `<fingering>` children and even
/// text like `2–4` (substitution) or `1-3` (double-stop fingering), so the
/// element's raw text is kept verbatim, one `Fingering` per element, document
/// order preserved — the same shape MuseScore's own MusicXML import produces
/// (`importmusicxmlpass2.cpp`, which reads the text into a `TextBase`).
/// `substitute="yes"` marks an alternate fingering: it is kept with a role
/// annotation so downstream consumers can distinguish it, mirroring the MSCX
/// `<Fingering><style>` roles (`Role(mscxToken:)` treats an unrecognized token
/// as `.other(style:)`, which is exactly the "alternate" bucket).
extension MusicXMLNoteDecoder {
    /// The note's `<notations><technical><fingering>` children as `Fingering`
    /// values. A note without `<notations>` / `<technical>` / `<fingering>`
    /// decodes to `[]` — a fingering is an embellishment under the parser
    /// policy, never a score failure.
    static func decodeFingerings(_ node: XMLTreeNode) -> [Fingering] {
        guard let notations = node.first("notations"),
              let technical = notations.first("technical")
        else { return [] }
        return technical.all("fingering").map(decodeFingering)
    }

    /// Decode one `<fingering>` element.
    static func decodeFingering(_ node: XMLTreeNode) -> Fingering {
        let substitute = node.attributes["substitute"] == "yes"
        return Fingering(
            text: node.text ?? "",
            role: substitute ? .other(style: "substitute") : .fingering,
        )
    }
}
