#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The hit tester's last pass: engraved text — lyrics, staff / system text, chord symbols and rehearsal
/// marks. It runs only after the whole engraving ladder has declined the point; see `ScoreHitTarget` for why
/// the ordering matters and what each target's identity is for.
@available(macOS 15.0, *)
extension ScoreHitTester {
    /// How far outside its measured ink box a text element still answers a click, in **spatium units** —
    /// the box is inset by `sp * this` on all four sides before the containment test.
    ///
    /// Text sets much thinner ink than a notehead: a lyric's box is only as tall as one line of Edwin and a
    /// chord symbol can be two characters wide, so an exact-box test makes editing text a precision
    /// exercise. A quarter of a staff space scales with the staff the way the type does, and is about the
    /// stroke width of the glyphs themselves.
    ///
    /// Sized against the tightest neighbours these boxes have, consecutive lyric verses, and it fits with
    /// room to spare. Measured at the default `staffSize: 28` (sp = 7): the lyrics row sets at 14 pt, whose
    /// ascent + descent is 14.0 pt, while `lyricVerseStrideInSpatiums` puts the next verse's centre only
    /// 11.9 pt below. The two boxes therefore ALREADY overlap by 2.1 pt with no tolerance at all — verse 0
    /// is emitted first and wins that shared band. Padding widens the overlap to 5.6 pt, which still ends
    /// 3.2 pt above verse 1's own centre line, so every click on a verse's actual glyphs keeps reporting
    /// that verse. Roughly half a spatium is where that stops being true.
    static let textHitTolerance: CGFloat = 0.25

    /// The text element under `point`, or `nil`. `base` is the measure's document-space origin.
    ///
    /// Every box comes from `LayoutElementShape.autoplacedRects(for:kind:metrics:)` — the same measurement
    /// the skyline pass uses to decide where these elements were allowed to sit, which resolves the font
    /// through `TextRoleStyle` exactly as `ResolvedTextStyle` does for the renderers. Measuring a second
    /// time here would give the host two answers that could disagree; the whole reason this pass lives in
    /// the library is so a host never has to resolve a `TextStyleType` to a font to ask what it clicked.
    ///
    /// Elements whose identity is `nil` are skipped rather than reported without one: there is no command
    /// that could act on them (see `ScoreHitTarget`).
    func hitText(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let tolerance = sp * Self.textHitTolerance
        for element in measure.elements {
            guard let (kind, target) = Self.textTarget(for: element) else { continue }
            let rects = LayoutElementShape.autoplacedRects(
                for: element, kind: kind, metrics: document.metrics,
            )
            for rect in rects {
                let box = rect
                    .offsetBy(dx: base.x, dy: base.y)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                if box.contains(point) { return target }
            }
        }
        return nil
    }

    /// The skyline kind to measure `element` as, paired with the target a hit on it reports — or `nil` when
    /// `element` is not addressable text.
    private static func textTarget(
        for element: LayoutElement,
    ) -> (kind: ShapeItemKind, target: ScoreHitTarget)? {
        switch element {
        case let .textMark(.lyrics(_, verse, anchor), _, _):
            guard let anchor else { return nil }
            return (.lyrics, .lyric(anchor: anchor, verse: verse))
        case let .staffText(_, _, _, style, anchor):
            guard let anchor else { return nil }
            // `.instrumentChange` reaches the page through this case but is a separate model element with
            // no text-entry command, so it is not a target even when placement recovered an anchor for it.
            switch style {
            case .staffText: return (.staffText, .staffText(anchor: anchor, style: style))
            case .systemText: return (.systemText, .staffText(anchor: anchor, style: style))
            default: return nil
            }
        case let .harmony(harmony):
            guard let anchor = harmony.anchor else { return nil }
            return (.harmony, .harmony(anchor: anchor))
        case let .rehearsalMark(_, _, _, _, measureIndex):
            return (.rehearsalMark, .rehearsalMark(measureIndex: measureIndex))
        default:
            return nil
        }
    }
}
