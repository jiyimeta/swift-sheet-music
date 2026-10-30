import SheetMusicFoundation

/// Per-chord articulation marking. C++: `mu::engraving::Articulation`.
///
/// The duration-shaping family (staccato / staccatissimo and its stroke and wedge / tenuto / tenutoStaccato, and the
/// soft-accent combinations that carry one of those) and velocity-shaping family (accent / marcato / accentStaccato /
/// marcatoStaccato / tenutoAccent / marcatoTenuto) are consumed by the MIDI renderer, as is the cymbal choke, which
/// stops the note at the end of its tie chain on a backend that understands the choke marker. The rest are drawn but
/// play as written. Any other subtype decoded from mscx is preserved as `.unknown(subtype:)` so the encoder can emit
/// the same XML back, but neither the layout nor the renderer reads it.
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

    /// Every case but `.unknown` and `.laissezVibrer` is one of MuseScore's Articulations palette entries
    /// (`newArticulationsPalette`, default and master lists), named after its SymId.
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
        /// articLaissezVibrerAbove/Below — how MuseScore before 4.5 stored a laissez vibrer, as an articulation. 4.5
        /// turns it into a `<LaissezVib>` tie on the note (`CompatUtils::convertLaissezVibArticToTie`), which this
        /// package does not model; the articulation form is drawn as its SMuFL symbol and plays as written.
        case laissezVibrer
        /// pictChokeCymbal — "stop the cymbal at the end of the written value". Not in MuseScore's Articulations
        /// palette, but MuseScore reads any SymId name as an articulation subtype, so it opens there as this symbol.
        /// One symbol, no `Above` / `Below` pair.
        case chokeCymbal
        /// Any subtype outside the in-scope set above. The raw MS4
        /// SymId (e.g. `handbellsMartellato`) is preserved verbatim.
        case unknown(subtype: String)

        /// Every modeled kind, in declaration order — what `init?(mscxToken:)` searches.
        public static let modeled: [Kind] = [
            .staccato, .staccatissimo, .tenuto, .accent, .marcato, .accentStaccato, .marcatoStaccato,
            .tenutoStaccato, .tenutoAccent, .marcatoTenuto, .staccatissimoStroke, .staccatissimoWedge, .stress,
            .unstress, .softAccent, .softAccentStaccato, .softAccentTenuto, .softAccentTenutoStaccato, .muteOpen,
            .muteClosed, .harmonic, .upBow, .downBow, .laissezVibrer, .chokeCymbal,
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
            case .laissezVibrer: "articLaissezVibrer"
            case .chokeCymbal: "pictChokeCymbal"
            case let .unknown(subtype): subtype
            }
        }

        /// Whether MuseScore spells this kind as an `Above` / `Below` pair. The `artic…` SymIds do; the brass mutes,
        /// the harmonic, the bow marks and the choke are one symbol each, written bare, and always sit above the staff
        /// (MuseScore's `AnchorGroup::OTHER`, anchored `TOP`).
        public var hasPlacementVariants: Bool {
            switch self {
            case .muteOpen, .muteClosed, .harmonic, .upBow, .downBow, .chokeCymbal: false
            default: true
            }
        }

        /// Whether the MIDI renderer changes how a note plays for this kind: the velocity-shaping family and the
        /// duration-shaping family named in the type's doc, and the choke. Mirrors the cases
        /// `MidiRenderer.velocityPreset(for:)` and `MidiRenderer.gatePreset(for:)` answer, plus the choke marker the
        /// playback render emits (all in SheetMusicMIDI, which this module cannot see);
        /// `ChordArticulationPlaybackTests` renders every kind and fails when the two drift apart. A kind that does not
        /// shape playback is drawn and plays as written.
        var shapesPlayback: Bool {
            switch self {
            case .staccato, .staccatissimo, .tenuto, .accent, .marcato, .accentStaccato, .marcatoStaccato,
                 .tenutoStaccato, .tenutoAccent, .marcatoTenuto, .staccatissimoStroke, .staccatissimoWedge,
                 .softAccentStaccato, .softAccentTenuto, .softAccentTenutoStaccato, .chokeCymbal:
                true
            case .stress, .unstress, .softAccent, .muteOpen, .muteClosed, .harmonic, .upBow, .downBow,
                 .laissezVibrer, .unknown:
                false
            }
        }

        /// The General MIDI keys `.chokeCymbal` stops on a drum staff — crash 1, ride 1, china, ride bell, splash,
        /// crash 2, ride 2 — judged by the note's playback key. A kick, a snare or a hi-hat in the same chord rings on;
        /// on a pitched staff every note of the chord is choked. Here rather than in SheetMusicMIDI because the drum
        /// re-voicer reads it too; `ChokeMarker.cymbalKeys` is this set.
        public static let chokedCymbalKeys: Set = [49, 51, 52, 53, 55, 57, 59]

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
