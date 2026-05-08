import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ChordArticulation {
    /// Build an `<Articulation><subtype>…</subtype></Articulation>`
    /// element. Inverse of `MSCXDecoder+Chord`'s harvest path.
    /// Both MS3 (3.6.2+) and MS4 readers accept the SymId-string form.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        _ = options // reserved for API consistency with neighbour encoders
        return XMLTreeNode(
            name: "Articulation",
            children: [XMLTreeNode(name: "subtype", text: subtypeXML())]
        )
    }

    /// Build the `<subtype>` payload. `unknown` writes the raw string
    /// verbatim (anchor ignored). Known kinds default `nil` anchor to
    /// `Above`, matching MuseScore's default for newly created
    /// articulations.
    func subtypeXML() -> String {
        if case let .unknown(raw) = kind {
            return raw
        }
        let suffix: String
        switch anchor {
        case .below: suffix = "Below"
        case .above, .none: suffix = "Above"
        }
        switch kind {
        case .staccato: return "articStaccato\(suffix)"
        case .staccatissimo: return "articStaccatissimo\(suffix)"
        case .tenuto: return "articTenuto\(suffix)"
        case .accent: return "articAccent\(suffix)"
        case .marcato: return "articMarcato\(suffix)"
        case .accentStaccato: return "articAccentStaccato\(suffix)"
        case .marcatoStaccato: return "articMarcatoStaccato\(suffix)"
        case .unknown: return "" // unreachable — handled above
        }
    }
}
