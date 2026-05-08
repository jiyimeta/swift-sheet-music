import Foundation

/// Per-chord articulation marking. C++: `mu::engraving::Articulation`.
///
/// The duration-shaping family (staccato / staccatissimo / tenuto) and
/// velocity-shaping family (accent / marcato / accentStaccato /
/// marcatoStaccato) are consumed by the MIDI renderer. Any other subtype
/// decoded from mscx is preserved as `.unknown(subtype:)` so the encoder
/// can emit the same XML back, but the renderer ignores it.
public struct ChordArticulation: Sendable, Equatable {
    public var kind: Kind
    /// Anchor side written by MuseScore (`articStaccatoAbove` vs
    /// `…Below`). Preserved verbatim for round-trip; encoder defaults
    /// to `.above` when `nil` (matches MuseScore's default for newly
    /// created articulations).
    public var anchor: Anchor?

    public init(kind: Kind, anchor: Anchor? = nil) {
        self.kind = kind
        self.anchor = anchor
    }

    public enum Kind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
        case accent // articAccentAbove/Below
        case marcato // articMarcatoAbove/Below
        case accentStaccato // articAccentStaccatoAbove/Below
        case marcatoStaccato // articMarcatoStaccatoAbove/Below
        /// Any subtype outside the in-scope set above. The raw MS4
        /// SymId (e.g. `articSoftAccentAbove`) is preserved verbatim.
        case unknown(subtype: String)
    }

    public enum Anchor: Sendable, Equatable {
        case above
        case below
    }
}
