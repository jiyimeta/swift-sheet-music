import SheetMusicFoundation

/// Free-form text label attached to a chord/rest position. Covers
/// both `<StaffText>` (per-staff) and `<SystemText>` (system-wide)
/// from MuseScore's `.mscx` format. Author-supplied color and
/// offset are preserved so the renderer can honor them.
///
/// C++: `mu::engraving::StaffTextBase` / `StaffText` / `SystemText`.
public struct StaffText: Sendable, Equatable {
    /// Plain-text content. Inline HTML formatting (e.g. `<font>`)
    /// remains available separately as opaque preserved markup.
    public var text: String
    public var preservedTextMarkup: PreservedTextMarkup?
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units. Sugar over `elementProperties.offset`.
    public var offsetX: Double {
        get { elementProperties.offset?.x ?? 0 }
        set {
            let y = elementProperties.offset?.y ?? 0
            elementProperties.offset = ScoreOffset(x: newValue, y: y)
        }
    }

    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down). Sugar over
    /// `elementProperties.offset`.
    public var offsetY: Double {
        get { elementProperties.offset?.y ?? 0 }
        set {
            let x = elementProperties.offset?.x ?? 0
            elementProperties.offset = ScoreOffset(x: x, y: newValue)
        }
    }

    /// Author-supplied color (RGBA 0..255). Nil = inherit the
    /// default text color. Sugar over `elementProperties.color` —
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
    /// Carries `<visible>`, `<color>`, and `<offset>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// What this staff text is besides text: a play-technique annotation or a harp pedal diagram. MuseScore reads
    /// both as staff-text-like annotations of a segment (`<PlayTechAnnotation>`, `<HarpPedalDiagram>`). Settable
    /// after init; the public initializer makes an ordinary staff text. No edit command reaches an annotated text
    /// (`SetStaffText` matches ordinary ones only), so `ScoreFingerprint` does not hash this field.
    package var annotation: Annotation?

    public init(
        text: String,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        isSystemText: Bool = false,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
        preservedTextMarkup: PreservedTextMarkup? = nil,
    ) {
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.isSystemText = isSystemText
        self.properties = properties
        let offset: ScoreOffset? = if offsetX == 0 && offsetY == 0 {
            nil
        } else {
            ScoreOffset(x: offsetX, y: offsetY)
        }
        elementProperties = ElementProperties(
            visible: visible, color: color, offset: offset,
        )
    }

    /// The `TextStyleType` row this element inherits from: a harp pedal diagram's own style, else `.systemText` when
    /// `isSystemText` is true and `.staffText` otherwise.
    public var styleType: TextStyleType {
        switch annotation {
        case let .harpPedal(diagram)?: diagram.isDiagram ? .harpPedalDiagram : .harpPedalTextDiagram
        default: isSystemText ? .systemText : .staffText
        }
    }
}

/// 8-bit per-channel RGBA color, mirroring MuseScore's
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
