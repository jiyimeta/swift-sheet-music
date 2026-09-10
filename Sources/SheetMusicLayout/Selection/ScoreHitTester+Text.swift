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

    /// Maximum distance from the rendered arc centerline, in spatium units.
    /// Chosen to match the local beam-segment threshold in `ScoreHitTester`.
    static let curveHitToleranceSp: CGFloat = 0.7

    /// Addressable text under a document-space point. Each component uses the renderer's font,
    /// multiline anchor, and actual outline bounds; frame strokes are included. Only this click
    /// path adds tolerance. Whitespace has no ink and cannot claim a click.
    func hitText(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let tolerance = sp * Self.textHitTolerance
        for element in measure.elements {
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
    public func textHitRect(for target: ScoreHitTarget) -> CGRect? {
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for element in measure.elements {
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
