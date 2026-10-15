import SheetMusicFoundation

/// Placement roles use independent position overrides; harmony variants share the harmony side.
public enum TextPlacementRole: String, CaseIterable, Sendable, Hashable {
    case lyrics, staffText, systemText, rehearsalMark, harmonyA, harmonyB, romanNumeral, nashvilleNumber
    case expression, sticking, harpPedalDiagram, harpPedalTextDiagram

    public var defaultPlacement: Placement {
        switch self {
        // `Sid::expressionPlacement`, `stickingPlacement`, `harpPedalTextDiagramPlacement` BELOW (styledef.cpp:1135,
        // 1641, 1042).
        case .lyrics, .expression, .sticking, .harpPedalTextDiagram: .below
        default: .above
        }
    }

    /// Baseline offsets from the selected staff edge, in spatiums.
    /// Behavioral reference: MuseScore 4.6 `styledef.cpp` text position defaults.
    public func defaultPosition(on side: Placement) -> ScoreOffset {
        let y: Double
        switch (self, side) {
        case (.lyrics, .above), (.systemText, .above), (.rehearsalMark, .above): y = -2
        case (.lyrics, .below): y = 3
        case (.staffText, .above): y = -1
        case (.staffText, .below): y = 2.5
        case (.rehearsalMark, .below): y = 4
        case (.harmonyB, .above): y = -5
        // `Sid::expressionPosAbove` (0, −1.5) / `PosBelow` (0, 2.5); `stickingPosAbove` (0, −1) / `PosBelow` (0, 2).
        case (.expression, .above): y = -1.5
        case (.expression, .below): y = 2.5
        case (.sticking, .above): y = -1
        case (.sticking, .below): y = 2
        // A harp pedal diagram's pos rows are never applied: it sits at the staff edge (its offset is `PointF()`).
        case (.harpPedalDiagram, _), (.harpPedalTextDiagram, _): y = 0
        case (_, .above): y = -2.5
        case (_, .below): y = 3.5
        }
        return ScoreOffset(x: 0, y: y)
    }
}

/// Only authored overrides are stored. Missing values resolve against the role at layout time.
public struct TextPlacementStyle: Sendable, Equatable {
    public var placement: Placement?
    public var positionAbove: ScoreOffset?
    public var positionBelow: ScoreOffset?

    public init(placement: Placement? = nil, positionAbove: ScoreOffset? = nil, positionBelow: ScoreOffset? = nil) {
        self.placement = placement
        self.positionAbove = positionAbove
        self.positionBelow = positionBelow
    }
}

public struct TextPlacementStyles: Sendable, Equatable {
    private var overrides: [TextPlacementRole: TextPlacementStyle] = [:]

    public init() {}

    public subscript(role: TextPlacementRole) -> TextPlacementStyle {
        get { overrides[role] ?? TextPlacementStyle() }
        set { overrides[role] = newValue == TextPlacementStyle() ? nil : newValue }
    }

    public func side(for role: TextPlacementRole, element: ElementProperties) -> Placement {
        let sharedRole: TextPlacementRole = [.harmonyB, .romanNumeral, .nashvilleNumber]
            .contains(role) ? .harmonyA : role
        return element.placement ?? self[sharedRole].placement ?? role.defaultPlacement
    }

    public func position(for role: TextPlacementRole, side: Placement) -> ScoreOffset {
        let value = side == .above ? self[role].positionAbove : self[role].positionBelow
        guard let value, value.x.isFinite, value.y.isFinite else { return role.defaultPosition(on: side) }
        return value
    }
}
