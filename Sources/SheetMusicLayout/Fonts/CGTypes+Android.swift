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
//
// WARNING for anyone consuming these types from outside this file's own module scope (Android bridge code,
// tests, or a future Task 8-10 draw program): `Foundation` on Android (swift-corelibs-foundation) ships its
// own complete `CGFloat`/`CGPoint`/`CGSize`/`CGRect` — including its own `intersects`/`contains`/`offsetBy` —
// as a Codable/Hashable-friendly value-type shim, entirely independent of the ones declared below. A file
// that does `import Foundation` alongside `import SheetMusicLayout` and then references `CGRect`/`CGPoint`/
// `CGFloat` unqualified silently resolves to *Foundation's* type, not this one — with no ambiguity error from
// the compiler. Files inside this module are unaffected (a local declaration always wins over an imported one
// within the same module), but any external consumer that needs both modules must either avoid `import
// Foundation` in that file, or fully qualify (`SheetMusicLayout.CGRect`) to be sure which implementation is
// running. `Tests/SheetMusicTests/Layout/CGRectNegativeSizeTests.swift` documents the empirical proof.

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

        /// `minX`/`maxX`/`minY`/`maxY` are normalized — the min/max of the two edges, not just `origin` and
        /// `origin + size` in that order — exactly like `CGRectGetMinX`/`MaxX`/`MinY`/`MaxY` on a rect with
        /// possibly-negative width/height. Every reader of this stub (this file's own `contains`/`intersects`,
        /// and any Layout code that reads these accessors directly) goes through them, so this is the one place
        /// that needs to know a rect can be built un-standardized; nothing downstream has to re-derive it. This
        /// is the property that keeps Android's geometry answering the same way CoreGraphics does on iOS.
        public var minX: CGFloat {
            min(origin.x, origin.x + size.width)
        }

        public var maxX: CGFloat {
            max(origin.x, origin.x + size.width)
        }

        public var minY: CGFloat {
            min(origin.y, origin.y + size.height)
        }

        public var maxY: CGFloat {
            max(origin.y, origin.y + size.height)
        }

        public var midX: CGFloat {
            (minX + maxX) / 2
        }

        public var midY: CGFloat {
            (minY + maxY) / 2
        }

        public var width: CGFloat {
            size.width
        }

        public var height: CGFloat {
            size.height
        }

        /// Whether `point` falls within the rect, edges included — matches `CGRect.contains(_:)`'s documented
        /// behavior that a point on the boundary counts as contained. Reads the normalized `minX`/`maxX`/
        /// `minY`/`maxY` above, so this answers correctly even for a rect built with negative width/height.
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
