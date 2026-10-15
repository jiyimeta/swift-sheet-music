import SheetMusicFoundation

/// A breath mark or caesura sitting between two chords in a voice.
///
/// MuseScore stores both families under one `<Breath>` element
/// distinguished by `<subtype>`. We split them by `Kind` because they
/// differ semantically: breath marks are visual articulations, while
/// caesuras additionally insert a measured silence during playback.
///
/// Position in `Voice.elements`: a `Breath` is an **independent voice
/// element** sitting after the chord it follows — exactly the segment
/// position MuseScore uses. It is not attached to a chord.
///
/// C++: `mu::engraving::Breath`.
public struct Breath: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case breathMark(BreathMarkStyle)
        case caesura(CaesuraStyle)
    }

    public enum BreathMarkStyle: String, Sendable, Equatable, CaseIterable {
        case comma, tick, upbow, salzedo
    }

    public enum CaesuraStyle: String, Sendable, Equatable, CaseIterable {
        case normal, short, thick, curved, chant, singleStroke
    }

    public var kind: Kind

    /// Seconds of silence inserted after the preceding chord during
    /// MIDI playback. Caesura defaults are non-zero (style-dependent);
    /// breath marks default to `0` (visual-only) — matching MuseScore 4
    /// defaults. Mirrors MuseScore `<Breath><pause>`.
    public var pause: Double

    /// Base element properties shared with every engravable element.
    /// Carries `<visible>` and `<color>`; see `ElementProperties`.
    public var elementProperties: ElementProperties

    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(kind: Kind, pause: Double? = nil, visible: Bool = true) {
        self.kind = kind
        self.pause = pause ?? Self.defaultPause(for: kind)
        elementProperties = ElementProperties(visible: visible)
    }

    /// What an absent `<pause>` means in a MuseScore file: 0 for every kind (`propertyDefault(PAUSE)`,
    /// `dom/breath.cpp:134-135`; the 2.0 in `BREATH_LIST` is the palette's value). Measured on MuseScore 4.7.4's
    /// MIDI export: tag-less breaths and caesuras add no pause. It differs from `defaultPause(for:)`, the value
    /// folino's menu inserts.
    public static func fileDefaultPause(for _: Kind) -> Double {
        0
    }

    /// MuseScore 4 default pause in seconds. Breath marks are
    /// visual-only (0); caesuras insert a style-dependent silence.
    public static func defaultPause(for kind: Kind) -> Double {
        switch kind {
        case .breathMark:
            return 0
        case let .caesura(style):
            switch style {
            case .normal: return 0.5
            case .short: return 0.25
            case .thick: return 0.75
            case .curved: return 0.5
            case .chant, .singleStroke: return 0.5
            }
        }
    }
}
