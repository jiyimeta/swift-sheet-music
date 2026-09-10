#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Geometry for the box / circle around a rehearsal-mark label.
///
/// MuseScore's `Sid::rehearsalMarkFramePadding` (= 0.5 sp inset on every
/// side) and `Sid::rehearsalMarkFrameWidth` (= 0.16 sp stroke) are the
/// engraving defaults used here. The bounding rect is derived from the
/// caller-measured text width / height; the rendering platform supplies
/// the text measurement via its native font system.
public enum RehearsalMarkFrame {
    /// MuseScore default inset (`Sid::rehearsalMarkFramePadding`).
    public static func paddingSp(sp: CGFloat) -> CGFloat {
        sp * 0.5
    }

    /// MuseScore default stroke width (`Sid::rehearsalMarkFrameWidth`).
    public static func strokeWidthSp(sp: CGFloat) -> CGFloat {
        sp * 0.16
    }

    /// Frame-shape choice given the measured text dimensions.
    ///
    /// `origin` is the box's BOTTOM-LEADING corner (matching the
    /// renderer's anchor convention: y grows downward in layout
    /// coordinates, so the box's bottom edge sits at `origin.y` and
    /// the top edge at `origin.y - height`).
    public enum Shape: Sendable, Equatable {
        case none
        case rectangle(CGRect)
        case ellipse(CGRect)
    }

    /// Compute the bounding rectangle that encloses the text plus a
    /// `pad` border on every side. `origin` is the box's bottom-leading
    /// corner.
    public static func boxRect(
        textWidth: CGFloat, textHeight: CGFloat,
        origin: CGPoint, pad: CGFloat,
    ) -> CGRect {
        CGRect(
            x: origin.x,
            y: origin.y - 2 * pad - textHeight,
            width: textWidth + 2 * pad,
            height: textHeight + 2 * pad,
        )
    }

    /// Pick a frame around the nominal typographic box. A circle keeps the box center
    /// and its maximum dimension as the minimum diameter. When ink is supplied, grow
    /// only as needed to enclose every ink corner with the requested radial clearance.
    /// Clearance includes half the stroke width when measured to the painted inner edge.
    public static func shape(
        for frame: TextFrameType, around boxRect: CGRect,
        enclosing ink: CGRect? = nil, clearance: CGFloat = 0,
    ) -> Shape {
        switch frame {
        case .none:
            return .none
        case .rectangle:
            return .rectangle(boxRect)
        case .circle:
            var radius = max(boxRect.width, boxRect.height) / 2
            if let ink {
                let dx = max(abs(ink.minX - boxRect.midX), abs(ink.maxX - boxRect.midX))
                let dy = max(abs(ink.minY - boxRect.midY), abs(ink.maxY - boxRect.midY))
                radius = max(radius, (dx * dx + dy * dy).squareRoot() + clearance)
            }
            let diameter = radius * 2
            let inscribed = CGRect(
                x: boxRect.midX - diameter / 2,
                y: boxRect.midY - diameter / 2,
                width: diameter,
                height: diameter,
            )
            return .ellipse(inscribed)
        }
    }
}
