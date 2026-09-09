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
    /// ## What it costs, stated honestly: verse *n* eats the band above verse *n+1*'s centre
    ///
    /// Consecutive lyric verses are the tightest neighbours these boxes have, and they overlap. Measured at
    /// the default `staffSize: 28` (sp = 7): the lyrics row sets at 14 pt, whose ascent + descent is 14.0 pt,
    /// while `lyricVerseStrideInSpatiums` puts the next verse's centre only 11.9 pt below. So verse 0's box
    /// reaches 2.1 pt past verse 1's top edge **with no tolerance at all** — that part is intrinsic to the
    /// layout, not to this constant. The padding extends it to 5.6 pt, which reaches 3.85 pt below verse 1's
    /// own top edge; an ascender such as the "l" of "glo" peaks about 6.7 pt above its verse's centre, i.e.
    /// inside that band. **Clicking verse 1's ascender therefore reports verse 0.**
    ///
    /// The rule a caller can rely on is the weaker one: a click at or below a verse's centre line resolves to
    /// that verse, and the band above a verse's centre belongs to the verse above it. Shrinking the padding
    /// narrows the band but does not remove it, because 2.1 pt of it is there without any padding.
    ///
    /// Fixing it properly means letting the nearer centre win among overlapping lyric boxes rather than the
    /// first one emitted, which is a resolution policy this pass does not have and is out of scope here.
    static let textHitTolerance: CGFloat = 0.25

    /// The text element under `point`, or `nil`. `base` is the measure's document-space origin.
    ///
    /// Every box comes from `LayoutElementShape.autoplacedRects(for:kind:metrics:)`, measured under the kind
    /// `LayoutElementShape.kind(of:)` assigns — the same two calls the skyline pass makes to decide where
    /// these elements were allowed to sit, which resolve the font through `TextRoleStyle` exactly as
    /// `ResolvedTextStyle` does for the renderers. Measuring a second time here, or re-deriving the kind,
    /// would give the host two answers that could disagree; the whole reason this pass lives in the library
    /// is so a host never has to resolve a `TextStyleType` to a font to ask what it clicked.
    ///
    /// **Resolution among overlapping text is first match in `measure.elements` order**, which is emission
    /// order from `placeMeasureElements`. Nothing pins that order: verse 0 preceding verse 1 is incidental
    /// (`LayoutEngine+Placement` appends verses ascending), and where two different KINDS overlap — a chord
    /// symbol sitting over a staff text at the same beat — which one answers is likewise whichever the
    /// engine happened to append first. Any caller that needs a defined winner needs a resolution policy
    /// here, not a reading of the emission order.
    ///
    /// Elements whose identity is `nil` are skipped rather than reported without one: there is no command
    /// that could act on them (see `ScoreHitTarget`).
    func hitText(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let tolerance = sp * Self.textHitTolerance
        for element in measure.elements {
            guard let target = Self.textTarget(for: element),
                  let kind = LayoutElementShape.kind(of: element)
            else { continue }
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

    /// Document-coord rectangle of the engraved text identified by `target`, or `nil` when no layout
    /// element reports that target — a stale anchor after a re-layout, a verse that no longer exists, or a
    /// target that is not one of the four text cases at all.
    ///
    /// The identity-keyed counterpart of `hitText`, in the same shape as `ScoreHitTester.clefHitRect(for:)`:
    /// a host that has a target (from `hitTest(at:)`, or held across an edit) asks for the box to draw a
    /// selection highlight around, instead of re-resolving a `TextStyleType` to a font and measuring the run
    /// a second time. That second measurement is the thing this pass exists to spare a host — see
    /// `hitText`'s doc — and a host-side one would drift from the box the skyline actually reserved.
    ///
    /// The box is the SAME rect `hitText` tests, from the same `LayoutElementShape.autoplacedRects` call
    /// under the same `LayoutElementShape.kind(of:)`, but **without** `textHitTolerance`: the padding widens
    /// what a click may claim, and drawing it would show the reader a box larger than the ink. A caller that
    /// wants the click box back can inset by `sp * ScoreHitTester.textHitTolerance` itself.
    ///
    /// Where an element measures to more than one rect the union is returned, so the result is always one
    /// box. No text case produces more than one today.
    ///
    /// Resolution is first match in document order, which for a text target is also the only match: every
    /// identity here names one element (`.lyric` an anchor + verse, `.staffText` an anchor + style,
    /// `.harmony` an anchor, `.rehearsalMark` a bar). Unlike `hitText`'s first-match-wins among OVERLAPPING
    /// boxes, nothing is being resolved — the walk simply stops when it finds the element.
    public func textHitRect(for target: ScoreHitTarget) -> CGRect? {
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for element in measure.elements {
                    guard Self.textTarget(for: element) == target,
                          let kind = LayoutElementShape.kind(of: element)
                    else { continue }
                    let rects = LayoutElementShape.autoplacedRects(
                        for: element, kind: kind, metrics: document.metrics,
                    )
                    guard var box = rects.first else { continue }
                    for rect in rects.dropFirst() {
                        box = box.union(rect)
                    }
                    return box.offsetBy(dx: base.x, dy: base.y)
                }
            }
        }
        return nil
    }

    /// The target a hit on `element` reports, or `nil` when `element` is not addressable text.
    ///
    /// Only the box's measurement kind is decided here (via `LayoutElementShape.kind(of:)` in `hitText`);
    /// the identity extraction and the addressable / not-addressable decision are `LayoutElement.textID`'s,
    /// because `ScoreLayerBuilder` needs the same answer to register a text's layers for tinting. Its doc
    /// carries the three exclusions and why each is shaped the way it is.
    private static func textTarget(for element: LayoutElement) -> ScoreHitTarget? {
        element.textID.map(ScoreHitTarget.init(textID:))
    }
}
