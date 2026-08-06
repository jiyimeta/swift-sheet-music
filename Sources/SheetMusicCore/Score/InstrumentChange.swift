import Foundation

/// A mid-score instrument change: the engraved instruction text plus
/// the full `Instrument` that takes over from this position onward.
///
/// Stored as a `SystemElement` on `Score.systemMeasures`, the same lift
/// `<StaffText>` / `<SystemText>` / `<RehearsalMark>` already take. No
/// tick map is kept on `Part` — the time-keyed view is derived by
/// `Score.instrumentTimeline(forPart:)`, mirroring how `Tempo` is stored
/// as a system element and viewed through `TempoTimeline.build`.
///
/// C++: `mu::engraving::InstrumentChange` (a `TextBase` holding an
/// `Instrument` plus an `m_init` flag, `dom/instrchange.h:71-72`).
public struct InstrumentChange: Sendable, Equatable {
    /// The instrument taking over from here. `nil` for a text-only
    /// placeholder whose nested `<Instrument>` was unusable — the
    /// instruction still engraves, but playback is unaffected. The
    /// decoder emits a `ScoreDiagnostic` in that case.
    public var instrument: Instrument?
    /// Engraved instruction text, e.g. "アコーディオン に".
    public var text: String
    /// MuseScore's `<init>` flag. Written by the editing layer only,
    /// when the user actually picked an instrument in the dialog
    /// (`notation/internal/notationinteraction.cpp:2264`). No engraving
    /// or playback path reads it — preserved verbatim for round-trip
    /// fidelity and never acted upon.
    public var isUserInitialized: Bool
    /// Author-supplied X offset from the default placement, in spatium.
    public var offsetX: Double
    /// Author-supplied Y offset from the default placement, in spatium
    /// (positive = down).
    public var offsetY: Double
    /// Per-element font overrides; `nil` fields inherit the
    /// `instrumentChange` row of `TextStyleDefaults`.
    public var properties: TextProperties
    /// Base element properties shared with every engravable element
    /// (colour + `<visible>`).
    public var elementProperties: ElementProperties

    /// Author-supplied colour. Sugar over `elementProperties.color`.
    public var color: ScoreColor? {
        get { elementProperties.color }
        set { elementProperties.color = newValue }
    }

    /// MuseScore `<visible>0</visible>`. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// The `TextStyleType` row this element inherits from.
    public var styleType: TextStyleType {
        .instrumentChange
    }

    public init(
        text: String,
        instrument: Instrument? = nil,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        isUserInitialized: Bool = false,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.text = text
        self.instrument = instrument
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.isUserInitialized = isUserInitialized
        self.properties = properties
        elementProperties = ElementProperties(visible: visible, color: color)
    }
}
