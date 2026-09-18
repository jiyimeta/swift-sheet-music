#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Where a clef is drawn, for hosts that want to put something beside
/// it. Split out of `ScoreHitTester.swift`, whose struct body had
/// reached SwiftLint's 400-line budget; these two read no state the
/// rest of the hit tester keeps to itself.
@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Document-coord rectangle of the clef glyph identified by
    /// `anchor`: the FIRST place it is drawn. Returns nil when no
    /// layout element matches — e.g. after a re-layout invalidates the
    /// anchor.
    ///
    /// Each anchor names ONE drawn glyph: a continuation system's
    /// restatement names that system's head bar rather than the
    /// declaration it redraws, so the clef carried across three
    /// systems is three anchors, not one drawn three times. This
    /// therefore answers with the only rectangle there is.
    /// `clefHitRects(for:)` stays the primitive — it is a scan over
    /// the whole document, and nothing in the layout contract promises
    /// a scan finds at most one match.
    public func clefHitRect(for anchor: ClefAnchor) -> CGRect? {
        clefHitRects(for: anchor).first
    }

    /// Every place the clef identified by `anchor` is drawn, one
    /// rectangle each, in document order — normally exactly one, since
    /// each drawn clef carries its own anchor (see `ClefAnchor
    /// .restatement`).
    ///
    /// The clef counterpart of `elementHitRects(for:)`, and it exists
    /// for the same reason: a host floating a control beside the
    /// selection has to put it beside the glyph the reader actually
    /// clicked. It kept its plural shape when restatements stopped
    /// sharing their declaration's anchor, because the answer is a
    /// scan of the document rather than a promise about it.
    ///
    /// Answers for a hidden clef while it is drawn, matching the rung that can now select one
    /// (`LayoutMeasure.drawnElements`). Empty when no layout element matches the anchor.
    public func clefHitRects(for anchor: ClefAnchor) -> [CGRect] {
        let sp = document.metrics.sp
        var result: [CGRect] = []
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for el in measure.drawnElements {
                    guard case let .clef(rawType, origin, elAnchor) = el,
                          elAnchor == anchor
                    else { continue }
                    let yOffset = Self.clefYOffset(
                        rawType: rawType, sp: sp,
                    )
                    let centerX = base.x + origin.x
                    let anchorY = base.y + origin.y + yOffset
                    // The glyph's own INK, not the symmetrical box the hit
                    // test uses: a G clef reaches 4.4 sp above its anchor and
                    // 2.6 sp below it, so a control hung off the top of a
                    // ±2.5 sp box opens over the curl rather than above it.
                    let ink = ClefGlyph.inkExtentSp(
                        for: NotatedClef(rawType: rawType),
                    )
                    result.append(CGRect(
                        x: centerX - sp,
                        y: anchorY - ink.above * sp,
                        width: sp * 2,
                        height: (ink.above + ink.below) * sp,
                    ))
                }
            }
        }
        return result
    }
}
