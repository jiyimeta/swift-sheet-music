import SheetMusicFoundation

/// The variants of a `TextLineBase` spanner (pedal, text line, palm mute, let ring, guitar lines, hairpin line, volta).
/// MuseScore writes each only when it differs from the item's default, so a `nil` field means "the kind's default".
extension Spanner {
    /// MuseScore `HookType` (`types/types.h:660-662`), the integer in `<beginHookType>` / `<endHookType>`.
    public enum LineHookType: Sendable, Equatable {
        case none
        case hook90
        case hook45
        case hook90T
        case arrow
        case arrowFilled
        case rosette
        /// A code this model does not know; it is kept so a save writes it back.
        case other(Int)

        public init(code: Int) {
            switch code {
            case 0: self = .none
            case 1: self = .hook90
            case 2: self = .hook45
            case 3: self = .hook90T
            case 4: self = .arrow
            case 5: self = .arrowFilled
            case 6: self = .rosette
            default: self = .other(code)
            }
        }

        public var code: Int {
            switch self {
            case .none: 0
            case .hook90: 1
            case .hook45: 2
            case .hook90T: 3
            case .arrow: 4
            case .arrowFilled: 5
            case .rosette: 6
            case let .other(code): code
            }
        }
    }

    /// MuseScore `LineType` (`types/types.h:655-657`), the integer in `<lineStyle>`.
    public enum LineType: Int, Sendable, Equatable {
        case solid = 0
        case dashed = 1
        case dotted = 2
    }

    /// The `TextLineBase` properties a begin side's payload child carries (`TWrite::writeProperties(TextLineBase)`,
    /// `rw/write/twrite.cpp:1663-1672`).
    public struct LineProperties: Sendable, Equatable {
        public var beginHook: LineHookType?
        public var endHook: LineHookType?
        /// In spatia.
        public var beginHookHeight: Double?
        public var endHookHeight: Double?
        public var lineVisible: Bool?
        public var lineType: LineType?
        /// In line widths.
        public var dashLength: Double?
        public var dashGap: Double?
        /// In spatia.
        public var lineWidth: Double?
        /// MuseScore `<play>` (`Spanner::playSpanner`); false when the file says `<play>0</play>`.
        public var playsBack: Bool

        public init(
            beginHook: LineHookType? = nil,
            endHook: LineHookType? = nil,
            beginHookHeight: Double? = nil,
            endHookHeight: Double? = nil,
            lineVisible: Bool? = nil,
            lineType: LineType? = nil,
            dashLength: Double? = nil,
            dashGap: Double? = nil,
            lineWidth: Double? = nil,
            playsBack: Bool = true,
        ) {
            self.beginHook = beginHook
            self.endHook = endHook
            self.beginHookHeight = beginHookHeight
            self.endHookHeight = endHookHeight
            self.lineVisible = lineVisible
            self.lineType = lineType
            self.dashLength = dashLength
            self.dashGap = dashGap
            self.lineWidth = lineWidth
            self.playsBack = playsBack
        }
    }

    /// The four guitar lines, by their `<Spanner type>` tag (`types/typesconv.cpp:517-526`).
    public enum ChordTextLine: String, Sendable, Equatable, CaseIterable {
        case harmonicMark = "HarmonicMark"
        case rasgueado = "Rasgueado"
        case pickScrape = "PickScrape"
        case whammyBar = "WhammyBar"
    }
}
