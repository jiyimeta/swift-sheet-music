import SheetMusicFoundation

/// Per-chord articulation marking. C++: `mu::engraving::Articulation`.
///
/// The duration-shaping family (staccato / staccatissimo and its stroke and wedge / tenuto / tenutoStaccato, and the
/// soft-accent combinations that carry one of those) and velocity-shaping family (accent / marcato / accentStaccato /
/// marcatoStaccato / tenutoAccent / marcatoTenuto) are consumed by the MIDI renderer. The rest are drawn but play as
/// written. Any other subtype decoded from mscx is preserved as `.unknown(subtype:)` so the encoder can emit the same
/// XML back, but neither the layout nor the renderer reads it.
public struct ChordArticulation: Sendable, Equatable {
    public var kind: Kind
    /// Anchor side written by MuseScore (`articStaccatoAbove` vs
    /// `…Below`). Preserved verbatim for round-trip; encoder defaults
    /// to `.above` when `nil` (matches MuseScore's default for newly
    /// created articulations). Always `nil` for a kind whose SymId has no
    /// `Above` / `Below` pair (`Kind.hasPlacementVariants`).
    public var anchor: Anchor?

    public init(kind: Kind, anchor: Anchor? = nil) {
        self.kind = kind
        self.anchor = anchor
    }

    /// Every case but `.unknown` is one of MuseScore's Articulations palette entries (`newArticulationsPalette`,
    /// default and master lists), named after its SymId.
    public enum Kind: Sendable, Hashable {
        case staccato
        case staccatissimo
        case tenuto
        case accent // articAccentAbove/Below
        case marcato // articMarcatoAbove/Below
        case accentStaccato // articAccentStaccatoAbove/Below
        case marcatoStaccato // articMarcatoStaccatoAbove/Below
        /// Louré: the tenuto line over the staccato dot (articTenutoStaccatoAbove/Below). MuseScore calls it
        /// "portato" when it picks the instrument's playback preset.
        case tenutoStaccato
        case tenutoAccent // articTenutoAccentAbove/Below
        case marcatoTenuto // articMarcatoTenutoAbove/Below
        case staccatissimoStroke // articStaccatissimoStrokeAbove/Below
        case staccatissimoWedge // articStaccatissimoWedgeAbove/Below
        case stress // articStressAbove/Below
        case unstress // articUnstressAbove/Below
        case softAccent // articSoftAccentAbove/Below
        case softAccentStaccato // articSoftAccentStaccatoAbove/Below
        case softAccentTenuto // articSoftAccentTenutoAbove/Below
        case softAccentTenutoStaccato // articSoftAccentTenutoStaccatoAbove/Below
        case muteOpen // brassMuteOpen
        case muteClosed // brassMuteClosed
        case harmonic // stringsHarmonic
        case upBow // stringsUpBow
        case downBow // stringsDownBow
        /// Any subtype outside the in-scope set above. The raw MS4
        /// SymId (e.g. `articLaissezVibrerAbove`) is preserved verbatim.
        case unknown(subtype: String)

        /// Every modeled kind, in declaration order — what `init?(mscxToken:)` searches.
        public static let modeled: [Kind] = [
            .staccato, .staccatissimo, .tenuto, .accent, .marcato, .accentStaccato, .marcatoStaccato,
            .tenutoStaccato, .tenutoAccent, .marcatoTenuto, .staccatissimoStroke, .staccatissimoWedge, .stress,
            .unstress, .softAccent, .softAccentStaccato, .softAccentTenuto, .softAccentTenutoStaccato, .muteOpen,
            .muteClosed, .harmonic, .upBow, .downBow,
        ]

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
            case .tenutoStaccato: "articTenutoStaccato"
            case .tenutoAccent: "articTenutoAccent"
            case .marcatoTenuto: "articMarcatoTenuto"
            case .staccatissimoStroke: "articStaccatissimoStroke"
            case .staccatissimoWedge: "articStaccatissimoWedge"
            case .stress: "articStress"
            case .unstress: "articUnstress"
            case .softAccent: "articSoftAccent"
            case .softAccentStaccato: "articSoftAccentStaccato"
            case .softAccentTenuto: "articSoftAccentTenuto"
            case .softAccentTenutoStaccato: "articSoftAccentTenutoStaccato"
            case .muteOpen: "brassMuteOpen"
            case .muteClosed: "brassMuteClosed"
            case .harmonic: "stringsHarmonic"
            case .upBow: "stringsUpBow"
            case .downBow: "stringsDownBow"
            case let .unknown(subtype): subtype
            }
        }

        /// Whether MuseScore spells this kind as an `Above` / `Below` pair. The `artic…` SymIds do; the brass mutes,
        /// the harmonic and the bow marks are one symbol each, written bare, and always sit above the staff
        /// (MuseScore's `AnchorGroup::OTHER`, anchored `TOP`).
        public var hasPlacementVariants: Bool {
            switch self {
            case .muteOpen, .muteClosed, .harmonic, .upBow, .downBow: false
            default: true
            }
        }

        /// Reverse of `mscxToken` for the modeled kinds. `nil` for anything else — including an anchor-bearing
        /// string, since callers strip the anchor first. Never returns `.unknown`: a caller that wants the
        /// round-trip-preserving fallback builds it itself, so that "this is a kind I model" and "this is a string
        /// I keep" stay two different answers.
        public init?(mscxToken: String) {
            guard let kind = Self.modeled.first(where: { $0.mscxToken == mscxToken }) else { return nil }
            self = kind
        }
    }

    public enum Anchor: Sendable, Equatable {
        case above
        case below
    }
}
