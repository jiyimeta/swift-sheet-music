import Foundation

/// A rehearsal letter / number ("A", "B", "1サビ", …) attached to a
/// position within a voice. Visually drawn once per system above the
/// top staff at the start of the containing measure, often boxed or
/// circled. C++: `mu::engraving::RehearsalMark`.
///
/// MuseScore's runtime `Type` distinction (`Main` / `Additional`) is
/// not serialized in MSCX and is omitted here; both are represented
/// by the same struct.
public struct RehearsalMark: Sendable, Equatable {
    /// Frame kind alias kept for source compatibility. New code
    /// should reach for `TextFrameType` directly or read it via
    /// `properties.frameType` / `TextStyleType.rehearsalMark`.
    public typealias FrameKind = TextFrameType

    public var text: String
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units.
    public var offsetX: Double
    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down).
    public var offsetY: Double
    /// Author-supplied color (RGBA 0..255). Nil = inherit the
    /// default text color. Sugar over `elementProperties.color` —
    /// the single source of truth shared with every engravable element.
    public var color: ScoreColor? {
        get { elementProperties.color }
        set { elementProperties.color = newValue }
    }

    /// Frame around the text. Defaults to `.rectangle`, matching
    /// MuseScore's `Sid::rehearsalMarkFrameType` default.
    public var frame: TextFrameType
    /// Per-element font overrides. `nil`-fields inherit from the
    /// `rehearsalMark` style row.
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
        text: String,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        frame: TextFrameType = .rectangle,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.text = text
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.frame = frame
        self.properties = properties
        elementProperties = ElementProperties(visible: visible, color: color)
    }
}
