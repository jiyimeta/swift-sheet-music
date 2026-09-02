import SheetMusicFoundation

/// What kind of guitar bend a `GuitarBend` is. Raw values are MuseScore's
/// own, written verbatim as `<guitarBendType>`.
/// C++: `mu::engraving::GuitarBendType` (`dom/guitarbend.h:30`).
public enum GuitarBendType: Int, Sendable, Equatable {
    /// Bend up from the sounding note into the next one.
    case bend = 0
    /// The string is already bent when it is struck, then released.
    case preBend = 1
    /// Bend carried by a grace note attached to the principal.
    case graceNoteBend = 2
    /// Quarter-tone scoop with no notated destination pitch; begins and
    /// ends on the same note.
    case slightBend = 3
    /// Whammy-bar dive.
    case dive = 4
    /// Whammy-bar dive already depressed at the attack.
    case preDive = 5
    /// Whammy-bar dip (down and back up within one note).
    case dip = 6
    /// Whammy-bar scoop into the attack.
    case scoop = 7
}

/// A guitar bend starting on a note and running to a later one.
/// C++: `mu::engraving::GuitarBend` (`dom/guitarbend.h:50`), a subset.
///
/// MuseScore 4 stores bends as `<Spanner type="GuitarBend">` children of
/// `<Note>`: the begin side carries a nested `<GuitarBend>` block plus
/// `<next>`, the end side carries only `<prev>`. A slight bend puts both
/// sides on the same note. The legacy MuseScore 3 `<Bend>` element is a
/// different, unrelated encoding and is not modeled.
/// C++: `TWrite::write(const GuitarBend*, …)` (`rw/write/twrite.cpp:1543`),
/// `TRead::read(GuitarBend*, …)` (`rw/read460/tread.cpp:2860`).
///
/// The whammy-bar types (`dive`, `preDive`, `dip`, `scoop`) carry four
/// further properties in MuseScore — `guitarDiveTabPos`,
/// `guitarDipTremoloLine`, `guitarDiveIsSlack`, `guitarBendAmount` — that
/// this model does not hold yet; the decoder announces them and drops them.
public struct GuitarBend: Sendable, Equatable {
    /// Whether the horizontal "hold" line that follows a bend is drawn.
    /// `auto` lets the engraver decide. Raw values are MuseScore's.
    /// C++: `mu::engraving::GuitarBendShowHoldLine` (`dom/guitarbend.h:42`).
    public enum ShowHoldLine: Int, Sendable, Equatable {
        case auto = 0
        case show = 1
        case hide = 2
    }

    public var type: GuitarBendType
    /// Fraction of the bend's span at which the pitch starts moving.
    /// C++: `GuitarBend::startTimeFactor()`, default 0.
    public var startTimeFactor: Double
    /// Fraction of the bend's span at which the pitch reaches its target.
    /// C++: `GuitarBend::endTimeFactor()`, default 1.
    public var endTimeFactor: Double
    /// Optional intermediate hold point, present only when the user moved
    /// it. C++: `GuitarBend::targetTimeFactor()`, a `std::optional`.
    public var targetTimeFactor: Double?
    /// Engraving override for the hold line's visibility.
    public var showHoldLine: ShowHoldLine
    /// Whether MuseScore attached a `<GuitarBendHold>` line to this bend.
    /// C++: `GuitarBend::holdLine()`.
    public var hasHoldLine: Bool

    public init(
        type: GuitarBendType,
        startTimeFactor: Double = 0,
        endTimeFactor: Double = 1,
        targetTimeFactor: Double? = nil,
        showHoldLine: ShowHoldLine = .auto,
        hasHoldLine: Bool = false,
    ) {
        self.type = type
        self.startTimeFactor = startTimeFactor
        self.endTimeFactor = endTimeFactor
        self.targetTimeFactor = targetTimeFactor
        self.showHoldLine = showHoldLine
        self.hasHoldLine = hasHoldLine
    }
}
