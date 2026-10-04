import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordArticulation {
    /// Build an `<Articulation><subtype>…</subtype></Articulation>`
    /// element. Inverse of `MSCXDecoder+Chord`'s harvest path.
    /// Both MS3 (3.6.2+) and MS4 readers accept the SymId-string form.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        _ = options // reserved for API consistency with neighbor encoders
        return XMLTreeNode(
            name: "Articulation",
            children: [XMLTreeNode(name: "subtype", text: subtypeXML())],
        )
    }

    /// Build the `<subtype>` payload. `unknown` writes the raw string
    /// verbatim (anchor ignored), and so does a kind MuseScore spells
    /// without an `Above` / `Below` pair (`stringsUpBow`). Other known
    /// kinds default `nil` anchor to `Above`, matching MuseScore's
    /// default for newly created articulations.
    func subtypeXML() -> String {
        if case let .unknown(raw) = kind {
            return raw
        }
        guard kind.hasPlacementVariants else { return kind.mscxToken }
        let suffix: String
        switch anchor {
        case .below: suffix = "Below"
        case .above, .none: suffix = "Above"
        }
        return "\(kind.mscxToken)\(suffix)"
    }
}
