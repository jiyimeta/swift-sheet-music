import SheetMusicCore

/// The shared answer to which editable engraved element this geometry names.
/// Hit testing and renderer registration must both use this predicate so clickable and tintable
/// elements cannot diverge. An absent anchor means there is no command address to report.
extension LayoutElement {
    /// The command's identity, independent of geometry, clipping, and continuation flags.
    public var elementID: ScoreElementID? {
        switch self {
        case let .tieArc(_, _, _, identity): return identity
        case let .marker(_, _, _, identity), let .jump(_, _, identity): return identity
        case let .keySignature(_, _, _, _, _, measureIndex):
            return measureIndex.map { .keySignature(measureIndex: $0) }
        case let .timeSignature(_, _, _, _, measureIndex):
            return measureIndex.map { .timeSignature(measureIndex: $0) }
        case let .barLine(_, _, _, measureIndex, role):
            return measureIndex.map { .barLine(measureIndex: $0, role: role) }
        case let .textMark(.dynamic(anchor), _, _):
            return anchor.map { .dynamic(anchor: $0) }
        case let .textMark(.tempo(anchor), _, _):
            return anchor.map { .tempo(anchor: $0) }
        case let .fermata(_, _, anchor):
            return anchor.map { .fermata(anchor: $0) }
        case let .breath(_, _, anchor):
            return anchor.map { .breath(anchor: $0) }
        case let .articulation(kind, _, _, anchor):
            return anchor.map { .articulation(anchor: $0, kind: kind.modelKind) }
        case let .spannerSegment(kind, _, _, _, _, _, anchor):
            guard let anchor else { return nil }
            switch kind {
            case .hairpinOpen, .hairpinClose, .hairpinLine: return .spanner(anchor: anchor, kind: .hairpin)
            case .pedal: return .spanner(anchor: anchor, kind: .pedal)
            case .ottava: return .spanner(anchor: anchor, kind: .ottava)
            case .volta: return .spanner(anchor: anchor, kind: .volta)
            case .slur: return .slur(.voice(anchor))
            case .vibrato, .trill, .textLine, .palmMute, .letRing: return nil
            }
        default:
            return nil
        }
    }

    /// The same identity wrapped for selection and renderer registration.
    public var elementItemID: ScoreItemID? {
        elementID.map(ScoreItemID.element)
    }
}

extension LayoutElement.ArticulationKind {
    /// Preserve the model discriminator used by `SetArticulation`, without matching glyphs or geometry.
    fileprivate var modelKind: ChordArticulation.Kind {
        switch self {
        case .staccato: .staccato
        case .staccatissimo: .staccatissimo
        case .tenuto: .tenuto
        case .accent: .accent
        case .marcato: .marcato
        case .accentStaccato: .accentStaccato
        case .marcatoStaccato: .marcatoStaccato
        }
    }
}
