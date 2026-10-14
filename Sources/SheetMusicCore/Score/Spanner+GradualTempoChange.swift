import SheetMusicFoundation

/// MuseScore's `GradualTempoChangeType` (`engraving/types/types.h:965-978`), spelled as `<tempoChangeType>` writes it
/// (`engraving/types/typesconv.cpp:2138-2149`).
public enum GradualTempoChangeType: String, Sendable, CaseIterable {
    case undefined
    case accelerando
    case allargando
    case calando
    case lentando
    case morendo
    case precipitando
    case rallentando
    case ritardando
    case smorzando
    case sostenuto
    case stringendo

    /// The factor a change of this type applies when it states none (`DEFAULT_FACTORS_MAP`,
    /// `engraving/dom/gradualtempochange.cpp:99-111`); 1 — no change — for `.undefined`.
    public var defaultFactor: Double {
        switch self {
        case .undefined: 1
        case .accelerando: 1.33
        case .allargando, .lentando, .rallentando, .ritardando: 0.75
        case .calando, .morendo, .smorzando: 0.5
        case .precipitando: 1.15
        case .sostenuto: 0.95
        case .stringendo: 1.5
        }
    }
}

extension Spanner {
    /// MuseScore's `ChangeMethod` (`engraving/types/types.h:981`): the easing a hairpin's velocity and a gradual tempo
    /// change's tempo follow.
    public typealias ChangeMethod = HairpinPayload.VeloChangeMethod

    /// MuseScore `<GradualTempoChange>` payload (`mu::engraving::GradualTempoChange`). Meaningful only when
    /// `kind == .gradualTempoChange`; an end-side marker has none.
    public struct GradualTempoChangePayload: Sendable, Equatable {
        /// `<tempoChangeType>`.
        public var type: GradualTempoChangeType
        /// `<tempoChangeFactor>`: the target tempo as a multiple of the tempo where the change starts; `nil` = the
        /// type's default (`effectiveFactor`).
        public var factor: Double?
        /// `<tempoEasingMethod>`.
        public var easing: ChangeMethod
        /// `<play>`: `false` keeps the line on the page and out of the tempo map.
        public var playsBack: Bool
        /// The payload's children nothing models — hooks, line style, `<Segment>` offsets, … — written back as read.
        public var preservedMarkup: [PreservedXML]

        public init(
            type: GradualTempoChangeType = .undefined,
            factor: Double? = nil,
            easing: ChangeMethod = .normal,
            playsBack: Bool = true,
            preservedMarkup: [PreservedXML] = [],
        ) {
            self.type = type
            self.factor = factor
            self.easing = easing
            self.playsBack = playsBack
            self.preservedMarkup = preservedMarkup
        }

        /// The factor the change applies: its own, else its type's (`GradualTempoChange::tempoChangeFactor`,
        /// `gradualtempochange.cpp:154-161`). MuseScore applies a stored factor as is, so a `0` or negative one gives
        /// it a zero tempo; here it reads as `minimumFactor` (the stored `factor` keeps the file's value) and a
        /// non-finite one as the type's default, so the tempo map never sees a non-positive tempo.
        public var effectiveFactor: Double {
            guard let factor, factor.isFinite else { return type.defaultFactor }
            return max(factor, Self.minimumFactor)
        }

        /// The smallest factor `effectiveFactor` returns.
        static let minimumFactor = 0.01
    }
}
