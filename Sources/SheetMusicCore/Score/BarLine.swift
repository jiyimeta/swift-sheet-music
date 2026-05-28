import Foundation

/// Bar line marker. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::BarLine`.
public struct BarLine: Sendable, Equatable {
    public var subtype: String? // e.g. "end", "double", "start-repeat"

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(subtype: String? = nil, visible: Bool = true) {
        self.subtype = subtype
        elementProperties = ElementProperties(visible: visible)
    }
}
