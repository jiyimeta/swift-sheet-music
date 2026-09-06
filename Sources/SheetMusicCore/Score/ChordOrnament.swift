import SheetMusicFoundation

/// A trill, turn, mordent, or one of their baroque relatives, attached to a chord.
/// C++: `mu::engraving::Ornament` (`dom/ornament.h:29`).
///
/// MuseScore 4 split this out of `Articulation`: an ornament is still an
/// articulation in the class hierarchy, but it gained the state that makes it
/// *sound* — which scale degree the auxiliary note takes above and below the
/// written note, whether that note carries an accidental, and whether the
/// realization starts on the upper note. MuseScore 3 had none of that and wrote
/// ornaments as plain `<Articulation>` elements with an `ornament…` SymId.
///
/// What this type does **not** model, and why:
///
/// - **The cue-note `<Chord>`.** MuseScore may nest a whole chord inside an
///   ornament to show the auxiliary note as a small cue note. It is a *derived*
///   value — `Ornament::computeNotesAboveAndBelow` (`dom/ornament.cpp:253`)
///   rebuilds its pitch from the parent chord's top note on every layout — so
///   holding it here would put a value in the model that goes stale the moment
///   the note under it is edited. It rides through a round trip in
///   `preservedMarkup` instead.
/// - **`<direction>`.** An `Articulation` property rather than ornament state;
///   `ChordArticulation` does not model it either. It round-trips as preserved
///   markup.
/// - **`<offset>` and `<placement>`.** Shared `EngravingItem` state modeled by
///   `elementProperties`, not ornament-specific state or preserved markup.
///
/// Playback is not wired up: this library's MIDI renderer mirrors MuseScore's
/// compat SMF export and does not yet realize ornaments into notes. The
/// intervals are modeled so that it can.
public struct ChordOrnament: Sendable, Equatable {
    /// Which ornament this is. `<subtype>`, a SymId name.
    public var kind: Kind
    /// Scale degree of the auxiliary note **above** the written note.
    /// `<intervalAbove>`. `nil` means the tag was absent, i.e. MuseScore's
    /// default of `second,auto` (`Interval.default`) applies.
    /// C++: `Pid::INTERVAL_ABOVE`.
    public var intervalAbove: Interval?
    /// Scale degree of the auxiliary note **below** the written note.
    /// `<intervalBelow>`. `nil` means absent — see `intervalAbove`.
    public var intervalBelow: Interval?
    /// When the auxiliary notes' accidentals are drawn. `<ornamentShowAccidental>`,
    /// written as the enum's ordinal. `nil` means absent (`.default` applies).
    public var showAccidental: ShowAccidental?
    /// Whether the small cue note is drawn. `<ornamentShowCueNote>`.
    /// `nil` means absent (`.auto` applies). C++: `AutoOnOff`.
    public var showCueNote: CueNoteVisibility?
    /// Begin the realization on the auxiliary note above rather than on the
    /// written note. `<startOnUpperNote>`. `nil` means absent (false applies).
    public var startOnUpperNote: Bool?
    /// Baroque vs. default realization. `<ornamentStyle>`. `nil` means absent.
    /// C++: `Pid::ORNAMENT_STYLE`, shared with `Articulation`.
    public var ornamentStyle: Style?
    /// Whether playback realizes this ornament at all. `<play>`. `nil` means
    /// absent (true applies).
    public var plays: Bool?
    /// Accidental drawn on the auxiliary note above. The `<Accidental>` child
    /// carrying `<placement>above</placement>`.
    public var accidentalAbove: Accidental?
    /// Accidental drawn on the auxiliary note below. The `<Accidental>` child
    /// without an explicit above placement — MuseScore's `PlacementV` default
    /// is `BELOW` (`dom/engravingitem.cpp:1689`), so the below accidental is
    /// written bare.
    public var accidentalBelow: Accidental?
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
    public var elementProperties: ElementProperties
    /// Source XML children this model does not represent — the cue-note
    /// `<Chord>` foremost.
    public var preservedMarkup: [PreservedXML]

    public init(
        kind: Kind,
        intervalAbove: Interval? = nil,
        intervalBelow: Interval? = nil,
        showAccidental: ShowAccidental? = nil,
        showCueNote: CueNoteVisibility? = nil,
        startOnUpperNote: Bool? = nil,
        ornamentStyle: Style? = nil,
        plays: Bool? = nil,
        accidentalAbove: Accidental? = nil,
        accidentalBelow: Accidental? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.kind = kind
        self.intervalAbove = intervalAbove
        self.intervalBelow = intervalBelow
        self.showAccidental = showAccidental
        self.showCueNote = showCueNote
        self.startOnUpperNote = startOnUpperNote
        self.ornamentStyle = ornamentStyle
        self.plays = plays
        self.accidentalAbove = accidentalAbove
        self.accidentalBelow = accidentalBelow
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}

extension ChordOrnament {
    /// The ornament symbols MuseScore's master ornaments palette offers
    /// (`palette/internal/palettecreator.cpp:796-818`), plus the escape hatch
    /// every MSCX enum in this library carries.
    ///
    /// Modeled as a closed set with `.unknown` rather than an open SymId string
    /// for the same reason `ChordArticulation.Kind` is: playback and engraving
    /// need to switch on the shape, and a subtype outside the palette still has
    /// to survive a round trip verbatim.
    public enum Kind: Sendable, Hashable {
        case turn
        case turnInverted
        case turnSlash
        case turnUp
        case turnUpS
        case trill
        case shortTrill
        case mordent
        case haydn
        case tremblement
        case prallMordent
        case upPrall
        /// MuseScore's palette entry for "down prall"; the SymId kept the
        /// `precompMordentUpperPrefix` spelling.
        case precompMordentUpperPrefix
        case upMordent
        case downMordent
        case prallDown
        case prallUp
        case linePrall
        case precompSlide
        case shake3
        case shakeMuffat1
        case tremblementCouperin
        case pinceCouperin
        /// A `<subtype>` outside the modeled set, kept verbatim so the encoder
        /// can write the same string back.
        case unknown(subtype: String)

        /// The SymId name this kind spells — the `<subtype>` text. `.unknown`
        /// answers with the raw string it preserved.
        public var mscxToken: String {
            if case let .unknown(subtype) = self { return subtype }
            return Self.tokensByKind[self] ?? ""
        }

        /// Reverse of `mscxToken` for the modeled set. `nil` for anything else;
        /// like `ChordArticulation.Kind`, it never returns `.unknown`, so that
        /// "a kind I model" and "a string I keep" stay two different answers.
        public init?(mscxToken: String) {
            guard let kind = Self.kindsByToken[mscxToken] else { return nil }
            self = kind
        }

        /// Every modeled kind, in palette order.
        public static let modeled: [Kind] = table.map(\.kind)

        private static let table: [(kind: Kind, token: String)] = [
            (.turn, "ornamentTurn"),
            (.turnInverted, "ornamentTurnInverted"),
            (.turnSlash, "ornamentTurnSlash"),
            (.turnUp, "ornamentTurnUp"),
            (.turnUpS, "ornamentTurnUpS"),
            (.trill, "ornamentTrill"),
            (.shortTrill, "ornamentShortTrill"),
            (.mordent, "ornamentMordent"),
            (.haydn, "ornamentHaydn"),
            (.tremblement, "ornamentTremblement"),
            (.prallMordent, "ornamentPrallMordent"),
            (.upPrall, "ornamentUpPrall"),
            (.precompMordentUpperPrefix, "ornamentPrecompMordentUpperPrefix"),
            (.upMordent, "ornamentUpMordent"),
            (.downMordent, "ornamentDownMordent"),
            (.prallDown, "ornamentPrallDown"),
            (.prallUp, "ornamentPrallUp"),
            (.linePrall, "ornamentLinePrall"),
            (.precompSlide, "ornamentPrecompSlide"),
            (.shake3, "ornamentShake3"),
            (.shakeMuffat1, "ornamentShakeMuffat1"),
            (.tremblementCouperin, "ornamentTremblementCouperin"),
            (.pinceCouperin, "ornamentPinceCouperin"),
        ]

        private static let tokensByKind = Dictionary(
            uniqueKeysWithValues: table.map { ($0.kind, $0.token) },
        )
        private static let kindsByToken = Dictionary(
            uniqueKeysWithValues: table.map { ($0.token, $0.kind) },
        )
    }

    /// The scale degree an auxiliary note takes from the written note.
    /// C++: `mu::engraving::OrnamentInterval` (`types/types.h:766`), written as
    /// `"<step>,<type>"`.
    public struct Interval: Sendable, Hashable {
        /// C++: `IntervalStep`.
        public enum Step: String, Sendable, CaseIterable {
            case unison, second, third, fourth, fifth, sixth, seventh, octave
        }

        /// C++: `IntervalType`. Named for the musical term — a second is major
        /// or minor, a fourth perfect, diminished, or augmented — with `auto`
        /// meaning "take it from the key signature".
        public enum Quality: String, Sendable, CaseIterable {
            case auto, minor, major, perfect, diminished, augmented
        }

        public var step: Step
        public var quality: Quality

        public init(step: Step, quality: Quality) {
            self.step = step
            self.quality = quality
        }

        /// MuseScore's default for both intervals — `DEFAULT_ORNAMENT_INTERVAL`,
        /// the value `Ornament::propertyDefault` answers with
        /// (`dom/ornament.cpp:166`).
        public static let `default` = Interval(step: .second, quality: .auto)

        /// The `"<step>,<quality>"` text MuseScore writes.
        public var mscxToken: String {
            "\(step.rawValue),\(quality.rawValue)"
        }

        /// Parse `"<step>,<quality>"`. A malformed pair — wrong field count, or
        /// a token outside either table — falls back per field to
        /// `Interval.default`, matching `TConv::fromXml(const String&,
        /// OrnamentInterval)` (`types/typesconv.cpp:757`), which logs and keeps
        /// the default rather than rejecting the element.
        public init(mscxToken: String) {
            let fields = mscxToken.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                self = .default
                return
            }
            step = Step(rawValue: String(fields[0])) ?? Self.default.step
            quality = Quality(rawValue: String(fields[1])) ?? Self.default.quality
        }
    }

    /// When the auxiliary notes' accidentals are drawn.
    /// C++: `mu::engraving::OrnamentShowAccidental` (`types/types.h:797`).
    /// Persisted as the ordinal, not a name — MuseScore reads it with
    /// `OrnamentShowAccidental(e.readInt())` (`rw/read460/tread.cpp:385`).
    public enum ShowAccidental: Int, Sendable, CaseIterable {
        /// Follow the key signature and the bar's accidental state.
        case `default` = 0
        /// Draw one whenever the auxiliary note is altered.
        case anyAlteration = 1
        /// Always draw one.
        case always = 2
    }

    /// Whether the small cue note showing the auxiliary pitch is drawn.
    /// C++: `mu::engraving::AutoOnOff` (`types/types.h:392`); `auto` defers to
    /// `Ornament::showCueNote` (`dom/ornament.cpp:244`), which decides from the
    /// interval and the `trillAlwaysShowCueNote` style.
    public enum CueNoteVisibility: String, Sendable, CaseIterable {
        case auto, on, off
    }

    /// Realization convention. C++: `mu::engraving::OrnamentStyle`
    /// (`types/types.h:288`).
    public enum Style: String, Sendable, CaseIterable {
        case `default`, baroque
    }
}
