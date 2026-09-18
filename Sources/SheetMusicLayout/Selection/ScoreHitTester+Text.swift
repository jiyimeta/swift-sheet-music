#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The hit tester's last pass: engraved text — lyrics, staff / system text, chord symbols and rehearsal
/// marks. It runs only after the whole engraving ladder has declined the point; see `ScoreHitTarget` for why
/// the ordering matters and what each target's identity is for.
@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Click tolerance outside actual text/frame ink, in spatium units. Highlight geometry
    /// excludes this padding. Overlapping click boxes resolve in element emission order.
    static let textHitTolerance: CGFloat = 0.25

    /// Click tolerance outside an engraved ELEMENT's ink, in spatium units — see
    /// `ScoreHitTester+Element.swift`'s `hitTolerance(for:)` for why every kind gets the same small reach, and
    /// `hitClef` for the one target that applies it to a glyph box rather than to measured ink.
    ///
    /// Half a staff space. Highlight geometry excludes it, exactly as it excludes the text padding above.
    static let elementHitTolerance: CGFloat = 0.5

    /// Maximum distance from the rendered arc centerline, in spatium units.
    /// Chosen to match the local beam-segment threshold in `ScoreHitTester`.
    static let curveHitToleranceSp: CGFloat = 0.7

    /// Addressable text under a document-space point. Each component uses the renderer's font,
    /// multiline anchor, and actual outline bounds; frame strokes are included. Only this click
    /// path adds tolerance. Whitespace has no ink and cannot claim a click.
    ///
    /// Searches everything the measure draws, hidden text included while it is drawn — see
    /// `LayoutMeasure.drawnElements`. A hidden syllable is exactly where an unhide command has to be aimed, and
    /// it was the report that sent this whole pass through `drawnElements`.
    func hitText(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let tolerance = sp * Self.textHitTolerance
        for element in measure.drawnElements {
            guard let target = Self.textTarget(for: element),
                  let rects = TextInkGeometry.rects(for: element, metrics: document.metrics)
            else { continue }
            for rect in rects {
                let box = rect
                    .offsetBy(dx: base.x, dy: base.y)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                if box.contains(point) { return target }
            }
        }
        return nil
    }

    /// Union of rendered text/frame ink in document coordinates, without click padding.
    /// Returns nil for a missing identity, unsupported target, or text with no painted ink.
    /// Separate harmony runs and rehearsal frames contribute their own component rectangles;
    /// `hitText` tests the components individually rather than the gaps in this union.
    ///
    /// Answers for drawn hidden text too, for the reason `hitText` searches it: a host floating a popover over
    /// the selection needs an anchor, and a selection this tester can now produce must not be one with nowhere
    /// to put it.
    public func textHitRect(for target: ScoreHitTarget) -> CGRect? {
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for element in measure.drawnElements {
                    guard Self.textTarget(for: element) == target,
                          let rects = TextInkGeometry.rects(for: element, metrics: document.metrics)
                    else { continue }
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

    /// Identity is shared with renderer tinting through `LayoutElement.textID`.
    private static func textTarget(for element: LayoutElement) -> ScoreHitTarget? {
        element.textID.map(ScoreHitTarget.init(textID:))
    }
}
