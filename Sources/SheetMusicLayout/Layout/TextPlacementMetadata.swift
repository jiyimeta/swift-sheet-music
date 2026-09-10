import SheetMusicCore

/// Stable lyric row identity, independent of offsets and collision-driven coordinates.
public struct LyricRow: Sendable, Equatable, Hashable {
    public let side: Placement
    public let verse: Int

    public init(side: Placement, verse: Int) {
        self.side = side
        self.verse = verse
    }
}

/// Layout-only state; renderers do not need a new draw-wire field.
public struct TextPlacementMetadata: Sendable, Equatable {
    public let side: Placement
    public let autoplace: Bool
    public let verse: Int?
    public let staff: StaffAddress?

    public init(side: Placement, autoplace: Bool = true, verse: Int? = nil, staff: StaffAddress? = nil) {
        self.side = side
        self.autoplace = autoplace
        self.verse = verse
        self.staff = staff
    }

    public var row: LyricRow? {
        verse.map { LyricRow(side: side, verse: $0) }
    }
}

extension LayoutElement {
    public var textPlacement: TextPlacementMetadata? {
        switch self {
        case let .textMark(.lyrics(_, _, _, placement), _, _),
             let .staffText(_, _, _, _, _, placement),
             let .rehearsalMark(_, _, _, _, _, placement),
             let .lyricsMelisma(_, _, placement), let .lyricHyphen(_, _, placement): placement
        case let .harmony(harmony): harmony.placement
        default: nil
        }
    }
}
