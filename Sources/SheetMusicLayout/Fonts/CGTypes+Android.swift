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
    }

#endif
