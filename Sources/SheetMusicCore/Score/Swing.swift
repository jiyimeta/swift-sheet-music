import SheetMusicFoundation

/// Swing rhythm directive. MuseScore exposes swing two ways:
///
/// 1. `Score.style.swingUnit` / `swingRatio` — global default applied
///    from the score start.
/// 2. A swing-flagged StaffText / SystemText placed inside a voice —
///    switches the swing setting from that point on (mid-piece change).
///
/// Both share the same two parameters; this struct models the
/// in-piece directive. `unit` selects which subdivision swings
/// (`.eighth` or `.sixteenth`); `.off` straightens. `ratio` is in
/// percent: 50 = perfect 50:50 (straight), 60 = MuseScore's default
/// soft swing, 67 ≈ classic 2:1, 75 = perfect triplet.
///
/// On disk MuseScore writes a `<StaffText>` (or `<SystemText>`) with
/// a `<swing unit="eighth|16th|" ratio="N"/>` child marking the text
/// as a swing controller. The decoder collapses that into this case;
/// the encoder restores it.
///
/// C++: `mu::engraving::StaffTextBase::swingParameters()` /
/// `engraving/dom/swing.{h,cpp}`.
public struct Swing: Sendable, Equatable {
    /// Display label. MuseScore writes "Swing" by default; user-edited
    /// labels (e.g. "Shuffle") round-trip through `<text>`.
    public var text: String
    /// Swing subdivision target. `.off` disables swing from this
    /// point even if the global Style enables it.
    public var unit: SwingUnit
    /// Swing ratio in percent. 50 = straight; values above 50 lengthen
    /// the down-beat. MuseScore's UI clamps to 50…75 but the field is
    /// preserved as-written here.
    public var ratio: Int
    /// True when this directive came from a `<SystemText>` element
    /// (system-flagged: applies to every staff). False for a
    /// `<StaffText>` directive that affects only the staff it sits on.
    /// Mirrors `StaffTextBase::systemFlag()` checked by
    /// `Score::updateSwing`.
    public var isSystemText: Bool
    public var offsetX: Double
    public var offsetY: Double
    /// Author-supplied color. Sugar over `elementProperties.color` —
    /// the single source of truth shared with every engravable element.
    public var color: ScoreColor? {
        get { elementProperties.color }
        set { elementProperties.color = newValue }
    }

    public var properties: TextProperties
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        text: String = "Swing",
        unit: SwingUnit = .eighth,
        ratio: Int = 60,
        isSystemText: Bool = true,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.text = text
        self.unit = unit
        self.ratio = ratio
        self.isSystemText = isSystemText
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.properties = properties
        elementProperties = ElementProperties(visible: visible, color: color)
    }

    /// Swing-unit length in MIDI ticks for a given PPQ. Eighth =
    /// `division/2`, sixteenth = `division/4`, off = 0. Mirrors the
    /// inline mapping in `Staff::swing()` (staff.cpp:1006).
    public func swingUnitTicks(division: Int) -> Int {
        switch unit {
        case .off: 0
        case .eighth: division / 2
        case .sixteenth: division / 4
        }
    }
}

/// The subdivision a swing directive applies to. `.off` disables swing
/// without removing the parameter (used to switch swing off mid-piece
/// while leaving the ratio recorded). Maps to MuseScore's
/// `DurationType::V_EIGHTH` / `V_16TH` / `V_ZERO` on the wire.
public enum SwingUnit: String, Sendable, Equatable, CaseIterable {
    case off
    case eighth
    case sixteenth

    /// MuseScore's `DurationType` XML form. Empty string for `.off`.
    public var mscxString: String {
        switch self {
        case .off: ""
        case .eighth: "eighth"
        case .sixteenth: "16th"
        }
    }

    /// Inverse of `mscxString`. Returns nil for unrecognized values
    /// so the caller can apply its own fallback (defaults to `.off`).
    public init?(mscxString: String) {
        switch mscxString {
        case "", "zero": self = .off
        case "eighth": self = .eighth
        case "16th": self = .sixteenth
        default: return nil
        }
    }
}
