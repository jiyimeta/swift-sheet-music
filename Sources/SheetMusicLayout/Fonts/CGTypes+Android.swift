// Minimal CoreGraphics-shaped value types for non-Apple platforms.
//
// SheetMusicLayout is pure geometry — it uses `CGFloat`, `CGPoint`,
// `CGSize`, `CGRect` extensively to describe positions on the page,
// but it never reaches into CoreGraphics' drawing surface (CGContext,
// CGPath, etc.). On Apple platforms these come from `CoreGraphics`
// itself; on Android (and any other `!canImport(CoreGraphics)` target)
// this file provides API-compatible stand-ins so the rest of the
// target compiles unchanged.
//
// Only the fields and initializers actually used by Layout are
// included. Do not add helpers pre-emptively — if a new CG API is
// referenced in Layout code, surface it here at that point.

#if !canImport(CoreGraphics)

    import Foundation

    public typealias CGFloat = Double

    public struct CGPoint: Hashable, Sendable {
        public var x: CGFloat
        public var y: CGFloat
        public init(x: CGFloat = 0, y: CGFloat = 0) {
            self.x = x
            self.y = y
        }

        public static let zero = CGPoint()
    }

    public struct CGSize: Hashable, Sendable {
        public var width: CGFloat
        public var height: CGFloat
        public init(width: CGFloat = 0, height: CGFloat = 0) {
            self.width = width
            self.height = height
        }

        public static let zero = CGSize()
    }

    public struct CGRect: Hashable, Sendable {
        public var origin: CGPoint
        public var size: CGSize
        public init(origin: CGPoint = .init(), size: CGSize = .init()) {
            self.origin = origin
            self.size = size
        }

        public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            origin = .init(x: x, y: y)
            size = .init(width: width, height: height)
        }

        public static let zero = CGRect()
        public var minX: CGFloat {
            origin.x
        }

        public var maxX: CGFloat {
            origin.x + size.width
        }

        public var minY: CGFloat {
            origin.y
        }

        public var maxY: CGFloat {
            origin.y + size.height
        }

        public var midX: CGFloat {
            origin.x + size.width / 2
        }

        public var midY: CGFloat {
            origin.y + size.height / 2
        }

        public var width: CGFloat {
            size.width
        }

        public var height: CGFloat {
            size.height
        }

        /// Whether `point` falls within the rect, edges included — matches `CGRect.contains(_:)`'s documented
        /// behavior that a point on the boundary counts as contained.
        public func contains(_ point: CGPoint) -> Bool {
            point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
        }

        /// Whether the two rects share any area. A merely-touching pair (shared edge, zero-width/height overlap)
        /// does not intersect — mirrors `CGRect.intersects(_:)`, which requires a non-degenerate intersection.
        public func intersects(_ other: CGRect) -> Bool {
            let ix0 = max(minX, other.minX)
            let iy0 = max(minY, other.minY)
            let ix1 = min(maxX, other.maxX)
            let iy1 = min(maxY, other.maxY)
            return ix1 > ix0 && iy1 > iy0
        }

        /// A copy of the rect translated by `(dx, dy)`, matching `CGRect.offsetBy(dx:dy:)`.
        public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
            CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
        }
    }

#endif
