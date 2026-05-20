import SheetMusicCore

/// Glyph / text selection for navigation markers (segno, coda, Fine,
/// D.C., D.S., …).
///
/// MuseScore renders segno-family and coda-family markers as SMuFL
/// glyphs from the music font; everything else (Fine, To Coda, D.C.,
/// D.S., and free-form `.other`) is drawn as expression text.
public enum MarkerGlyph {
    public enum Variant: Sendable, Equatable {
        case glyph(codepoint: UInt32)
        case text(label: String)
    }

    public static func variant(
        for kind: Marker.Kind, text: String,
    ) -> Variant {
        switch kind {
        case .segno, .varsegno:
            return .glyph(codepoint: SMuFLCodepoint.segno)
        case .coda, .varcoda, .codetta, .toCodaSym:
            return .glyph(codepoint: SMuFLCodepoint.coda)
        case .fine, .toCoda, .daCapo, .dalSegno, .other:
            let label = text.isEmpty ? fallbackLabel(for: kind) : text
            return .text(label: label)
        }
    }

    public static func fallbackLabel(for kind: Marker.Kind) -> String {
        switch kind {
        case .fine: return "Fine"
        case .toCoda: return "To Coda"
        case .daCapo: return "D.C."
        case .dalSegno: return "D.S."
        default: return ""
        }
    }
}
