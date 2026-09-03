import SheetMusicFoundation

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

        /// The MuseScore SymId base this kind spells, with no `Above` / `Below` anchor suffix — the string the
        /// MSCX decoder matches after stripping the anchor and the encoder re-suffixes. `.unknown` answers with
        /// the raw string it preserved, which is already anchor-bearing and goes out verbatim.
        ///
        /// Lives here rather than in `SheetMusicMSCX` because `SetArticulation` travels as this token on the wire
        /// (spec §4.2: an enum whose case order this codec does not own is a raw string), and `SheetMusicEditWire`
        /// does not depend on the MSCX module. The same move `Dynamic.defaultVelocity(for:)` made in group 3.
        public var mscxToken: String {
            switch self {
            case .staccato: "articStaccato"
            case .staccatissimo: "articStaccatissimo"
            case .tenuto: "articTenuto"
            case .accent: "articAccent"
            case .marcato: "articMarcato"
            case .accentStaccato: "articAccentStaccato"
            case .marcatoStaccato: "articMarcatoStaccato"
            case let .unknown(subtype): subtype
            }
        }

        /// Reverse of `mscxToken` for the seven in-scope kinds. `nil` for anything else — including an
        /// anchor-bearing string, since callers strip the anchor first. Never returns `.unknown`: a caller that
        /// wants the round-trip-preserving fallback builds it itself, so that "this is a kind I model" and "this
        /// is a string I keep" stay two different answers.
        public init?(mscxToken: String) {
            switch mscxToken {
            case "articStaccato": self = .staccato
            case "articStaccatissimo": self = .staccatissimo
            case "articTenuto": self = .tenuto
            case "articAccent": self = .accent
            case "articMarcato": self = .marcato
            case "articAccentStaccato": self = .accentStaccato
            case "articMarcatoStaccato": self = .marcatoStaccato
            default: return nil
            }
        }
    }

    public enum Anchor: Sendable, Equatable {
        case above
        case below
    }
}
