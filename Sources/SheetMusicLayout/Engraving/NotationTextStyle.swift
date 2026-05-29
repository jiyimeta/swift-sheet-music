#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Font size / italic / anchor constants for the small set of text
/// labels that aren't covered by `TextStyleType` (which mirrors
/// MuseScore's `Sid::*FontSize` table): measure numbers, staff names,
/// part labels, and D.C./D.S./Fine jumps.
///
/// Defined in `SheetMusicLayout` so the SwiftUI renderer, the CALayer
/// renderer, and the Android `LayoutBridge` resolve these constants
/// from a single source of truth.
public enum NotationTextStyle {
    public enum Role: Sendable, Equatable {
        case jump
        /// Fallback text label for non-glyph markers (Fine, D.C.,
        /// D.S., To Coda). The glyph markers (segno, coda) use
        /// `MarkerGlyph` instead.
        case markerText
        case measureNumber
        case staffName
        case partLabel
    }

    /// Final font size in points at the given staff spatium.
    public static func fontSize(for role: Role, sp: CGFloat) -> CGFloat {
        switch role {
        case .jump, .markerText, .partLabel: return sp * 2.5
        case .measureNumber, .staffName: return sp * 2.0
        }
    }

    public static func isItalic(for role: Role) -> Bool {
        switch role {
        case .jump: return true
        default: return false
        }
    }

    /// Anchor convention shared by the renderers. The concrete
    /// renderer maps these to its native API (SwiftUI's `UnitPoint`,
    /// `CGPoint(x:y:)` on `textLayer`, Canvas baseline-leading on
    /// Android).
    public enum Anchor: Sendable, Equatable {
        /// Vertical center, leading edge (SwiftUI `.leading`,
        /// `UnitPoint(x: 0, y: 0.5)`).
        case leadingCenter
        /// Bottom-leading: `UnitPoint(x: 0, y: 1)`.
        case bottomLeading
        /// Vertical center, trailing edge: `UnitPoint(x: 1, y: 0.5)`.
        case trailingCenter
    }

    public static func anchor(for role: Role) -> Anchor {
        switch role {
        case .jump, .markerText: return .leadingCenter
        case .measureNumber, .staffName: return .bottomLeading
        case .partLabel: return .trailingCenter
        }
    }
}
