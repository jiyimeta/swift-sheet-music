import Foundation

/// Free-form text label attached to a chord/rest position. Covers
/// both `<StaffText>` (per-staff) and `<SystemText>` (system-wide)
/// from MuseScore's `.mscx` format. Author-supplied colour and
/// offset are preserved so the renderer can honour them.
///
/// C++: `mu::engraving::StaffTextBase` / `StaffText` / `SystemText`.
public struct StaffText: Sendable, Equatable {
    /// Plain-text content. Inline HTML formatting (e.g. `<font>`)
    /// from the source is stripped during decode; visual styling
    /// other than colour is not yet preserved.
    public var text: String
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units.
    public var offsetX: Double
    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down).
    public var offsetY: Double
    /// Author-supplied colour (RGBA 0..255). Nil = inherit the
    /// default text colour. Sugar over `elementProperties.color` —
    /// the single source of truth shared with every engravable element.
    public var color: ScoreColor? {
        get { elementProperties.color }
        set { elementProperties.color = newValue }
    }

    /// True when this came from a `<SystemText>` element. System
    /// texts are conceptually shown once per system (typically
    /// above the top staff); staff texts attach to a specific
    /// staff.
    public var isSystemText: Bool
    /// Per-element font overrides. `nil`-fields inherit from the
    /// `staffText` / `systemText` row of `TextStyleDefaults`.
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
        isSystemText: Bool = false,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.text = text
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.isSystemText = isSystemText
        self.properties = properties
        elementProperties = ElementProperties(visible: visible, color: color)
    }

    /// The `TextStyleType` row this element inherits from. Picks
    /// `.systemText` when `isSystemText` is true.
    public var styleType: TextStyleType {
        isSystemText ? .systemText : .staffText
    }
}

/// 8-bit per-channel RGBA colour, mirroring MuseScore's
/// `<color r="…" g="…" b="…" a="…"/>` attributes. Kept Foundation-
/// only so it can live in `SheetMusicCore` without pulling in
/// CoreGraphics or SwiftUI.
public struct ScoreColor: Sendable, Equatable, Codable {
    public var red: Int
    public var green: Int
    public var blue: Int
    public var alpha: Int

    public init(red: Int, green: Int, blue: Int, alpha: Int = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
