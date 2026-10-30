#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The shared answer to which editable engraved element this geometry names.
/// Hit testing and renderer registration must both use this predicate so clickable and tintable
/// elements cannot diverge. An absent anchor means there is no command address to report.
extension LayoutElement {
    /// The command's identity, independent of geometry, clipping, and continuation flags.
    public var elementID: ScoreElementID? {
        switch self {
        case let .tieArc(_, _, _, identity): return identity
        case let .glissandoLine(_, _, _, _, start): return start.map { .glissando(start: $0) }
        case let .marker(_, _, _, identity, _, _, _), let .jump(_, _, identity, _, _, _): return identity
        // A swing marking, which prints as staff text and says which element it is here rather than through the
        // text `anchor` beside it — see `LayoutElement.staffText`. An ordinary staff text carries no identity and
        // falls through to `nil`, so the element rung declines it and the text rung answers for it.
        case let .staffText(_, _, _, _, _, _, _, identity, _): return identity
        case let .keySignature(_, _, _, _, _, identity), let .timeSignature(_, _, _, _, identity):
            return identity
        case let .barLine(_, _, _, measureIndex, role):
            return measureIndex.map { .barLine(measureIndex: $0, role: role) }
        case let .textMark(.dynamic(anchor), _, _, _):
            return anchor.map { .dynamic(anchor: $0) }
        case let .textMark(.tempo(anchor, _, _), _, _, _):
            return anchor.map { .tempo(anchor: $0) }
        case let .fermata(_, _, anchor):
            return anchor.map { .fermata(anchor: $0) }
        case let .breath(_, _, anchor):
            return anchor.map { .breath(anchor: $0) }
        case let .articulation(kind, _, _, anchor):
            return anchor.map { .articulation(anchor: $0, kind: kind.modelKind) }
        case let .arpeggioWiggle(_, _, _, anchor):
            return anchor.map { .arpeggio(anchor: $0) }
        case let .chordLine(_, _, _, anchor):
            return anchor.map { .chordLine(anchor: $0) }
        case let .tremoloBars(_, _, owner):
            return owner.map { .tremolo(anchor: $0) }
        case let .spannerSegment(kind, _, _, _, _, _, anchor, _, _):
            guard let anchor else { return nil }
            switch kind {
            case .hairpinOpen, .hairpinClose, .hairpinLine: return .spanner(anchor: anchor, kind: .hairpin)
            case .pedal: return .spanner(anchor: anchor, kind: .pedal)
            case .ottava: return .spanner(anchor: anchor, kind: .ottava)
            case .volta: return .spanner(anchor: anchor, kind: .volta)
            case .slur: return .slur(.voice(anchor))
            case .vibrato: return .spanner(anchor: anchor, kind: .vibrato)
            case .trill: return .spanner(anchor: anchor, kind: .trill)
            // Only a real text line reaches here with an anchor: a glissando or unrecognized `.spanner` draws as a
            // text line too, but `SpannerAnchor.selectionAnchor` gives it none.
            case .textLine: return .spanner(anchor: anchor, kind: .textLine)
            case .palmMute: return .spanner(anchor: anchor, kind: .palmMute)
            case .letRing: return .spanner(anchor: anchor, kind: .letRing)
            case .gradualTempoChange: return .spanner(anchor: anchor, kind: .gradualTempoChange)
            case .chordTextLine: return .spanner(anchor: anchor, kind: .chordTextLine)
            }
        default:
            return nil
        }
    }

    /// The same identity wrapped for selection and renderer registration.
    public var elementItemID: ScoreItemID? {
        elementID.map(ScoreItemID.element)
    }

    /// A slot selection names as a rest: a rest, or a measure repeat with its slot — MuseScore's `MeasureRepeat` is a
    /// `Rest` of the bar's length, so a click, a range and a cursor treat the sign as the bar's rest. Its identity,
    /// where it sits, its voice and its length. `nil` for anything else, and for a sign drawn with no slot.
    public var restSlot: (restID: RestID, origin: CGPoint, voiceIndex: Int, duration: NoteDuration)? {
        switch self {
        case let .rest(duration, origin, voiceIndex, restID, _):
            (restID, origin, voiceIndex, duration)
        case let .measureRepeat(_, origin, restID?):
            (restID, origin, restID.voiceIndex, .measure)
        default:
            nil
        }
    }

    /// Where a click selects `restSlot`, around its origin: a rest's generous box, `sp * 1.8` either side and
    /// `sp * 2.5` above and below; a measure repeat's ink — its glyph and a 2- or 4-bar one's number — with the
    /// half-space reach every engraved element gets, as MuseScore hits the sign by its shape. The rest's box spans
    /// the whole staff, which on a sign left no room above or below it to click the bar. `nil` with no slot.
    func restSlotHitRect(sp: CGFloat) -> CGRect? {
        switch self {
        case .rest:
            CGRect(x: -sp * 1.8, y: -sp * 2.5, width: sp * 3.6, height: sp * 5)
        case let .measureRepeat(count, _, _?):
            // `ScoreHitTester.elementHitTolerance`, which is not reachable from here below macOS 15.
            MeasureRepeatGlyph.drawnRect(forCount: count, sp: sp).insetBy(dx: -sp * 0.5, dy: -sp * 0.5)
        default:
            nil
        }
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
        case .tenutoStaccato: .tenutoStaccato
        case .tenutoAccent: .tenutoAccent
        case .marcatoTenuto: .marcatoTenuto
        case .staccatissimoStroke: .staccatissimoStroke
        case .staccatissimoWedge: .staccatissimoWedge
        case .stress: .stress
        case .unstress: .unstress
        case .softAccent: .softAccent
        case .softAccentStaccato: .softAccentStaccato
        case .softAccentTenuto: .softAccentTenuto
        case .softAccentTenutoStaccato: .softAccentTenutoStaccato
        case .muteOpen: .muteOpen
        case .muteClosed: .muteClosed
        case .harmonic: .harmonic
        case .upBow: .upBow
        case .downBow: .downBow
        case .laissezVibrer: .laissezVibrer
        case .chokeCymbal: .chokeCymbal
        }
    }
}
