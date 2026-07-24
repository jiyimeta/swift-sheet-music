import Foundation

/// A bezier (or straight, or wavy) line attached to a chord that
/// notates a jazz/brass inflection: fall, doit, plop, or scoop.
/// C++: `mu::engraving::ChordLine`.
///
/// MuseScore stores these as `<ChordLine>` elements. The element is a
/// child of `<Chord>` when it belongs to the chord as a whole, or a
/// child of `<Note>` when the user attached it to one specific note
/// of the chord (`ChordLine::setNote`). Both forms round-trip; see
/// `noteIndex`.
///
/// The `straight` / `wavy` flags select the palette variant:
///
/// | kind  | curved (default) | straight         | wavy                     |
/// |-------|------------------|------------------|--------------------------|
/// | fall  | Fall             | Slide out down   | Slide out down (rough)   |
/// | doit  | Doit             | Slide out up     | Slide out up (rough)     |
/// | plop  | Plop             | Slide in above   | Slide in above (rough)   |
/// | scoop | Scoop            | Slide in below   | Slide in below (rough)   |
///
/// C++: `TConv` `CHORDLINE_TYPES` table in `types/typesconv.cpp`.
public struct ChordLine: Sendable, Equatable {
    /// C++: `mu::engraving::ChordLineType`. The `<subtype>` values are
    /// `1`…`4`; `0` (`NOTYPE`) is not modelled — a subtype-less
    /// `<ChordLine>` draws nothing in MuseScore and is dropped by the
    /// decoder with a diagnostic.
    public enum Kind: Int, Sendable, Equatable, CaseIterable {
        case fall = 1
        case doit = 2
        case plop = 3
        case scoop = 4
    }

    /// One element of a user-edited `<Path>`. Mirrors
    /// `muse::draw::PainterPath::Element`; the `type` attribute
    /// MuseScore writes is this enum's raw value.
    ///
    /// A cubic segment is stored as a `.curveTo` (the first control
    /// point) followed by two `.curveToData` entries (the second
    /// control point and the end point) — see `TRead::read(ChordLine*)`.
    public struct PathElement: Sendable, Equatable {
        public enum Kind: Int, Sendable, Equatable {
            case moveTo = 0
            case lineTo = 1
            case curveTo = 2
            case curveToData = 3
        }

        public var kind: Kind
        /// X in spatium units (MuseScore divides by spatium on write).
        public var x: Double
        /// Y in spatium units.
        public var y: Double

        public init(kind: Kind, x: Double, y: Double) {
            self.kind = kind
            self.x = x
            self.y = y
        }
    }

    public var kind: Kind
    /// `<straight>` — draw a single straight segment instead of the
    /// default bezier. C++: `ChordLine::isStraight`.
    public var isStraight: Bool
    /// `<wavy>` — draw a SMuFL `brass…` wiggle glyph instead of a path.
    /// C++: `ChordLine::isWavy`.
    public var isWavy: Bool
    /// `<play>` — whether MuseScore's MPE playback model applies the
    /// matching articulation pattern. Preserved for round-trip only:
    /// this package's MIDI renderer mirrors MuseScore's *compat* SMF
    /// export, which ignores `ChordLine` entirely.
    public var plays: Bool
    /// `<lengthX>` — user drag adjustment, spatium units.
    public var lengthX: Double
    /// `<lengthY>` — user drag adjustment, spatium units.
    public var lengthY: Double
    /// A user-edited `<Path>`, in spatium units. Empty when the shape
    /// is the generated default — MuseScore only writes `<Path>` when
    /// `ChordLine::modified()`.
    public var path: [PathElement]
    /// Index into the owning chord's `notes` when MuseScore wrote this
    /// element under a `<Note>` rather than under `<Chord>`. `nil` for
    /// the chord-level form. Round-trip fidelity: the encoder puts the
    /// element back where it came from.
    public var noteIndex: Int?
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties

    /// MuseScore `<visible>0</visible>`. Sugar over `elementProperties`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        kind: Kind,
        isStraight: Bool = false,
        isWavy: Bool = false,
        plays: Bool = true,
        lengthX: Double = 0,
        lengthY: Double = 0,
        path: [PathElement] = [],
        noteIndex: Int? = nil,
    ) {
        self.kind = kind
        self.isStraight = isStraight
        self.isWavy = isWavy
        self.plays = plays
        self.lengthX = lengthX
        self.lengthY = lengthY
        self.path = path
        self.noteIndex = noteIndex
        elementProperties = ElementProperties()
    }
}

extension ChordLine {
    /// True when the line is drawn on the left of the notehead — the
    /// "slide in" family, which approaches the note from before it.
    /// C++: `ChordLine::isToTheLeft`.
    public var isToTheLeft: Bool {
        kind == .plop || kind == .scoop
    }

    /// True when the line descends below the notehead's vertical
    /// anchor. C++: `ChordLine::isBelow`.
    public var isBelow: Bool {
        kind == .scoop || kind == .fall
    }

    /// True when the default (unmodified) shape should be generated at
    /// layout time. MuseScore keys this off `ChordLine::modified()`,
    /// which the reader sets whenever a `<Path>` was present.
    public var hasUserPath: Bool {
        !path.isEmpty
    }
}
