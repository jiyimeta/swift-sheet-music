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

    // Nothing here needs Foundation — the types are built from `Double` and
    // `min`/`max`. Importing the umbrella from this one file was enough to pull
    // Foundation (and ICU) into the WebAssembly binary, which is the whole cost
    // the FoundationEssentials migration exists to avoid.

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

        /// Whether `point` falls within the rect — min-inclusive, max-**exclusive** on both axes, matching
        /// `CGRectContainsPoint`: `point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY` on the
        /// standardized rect. A point on the right or bottom edge is therefore *not* contained, and this is also
        /// what makes an empty rect (zero width or height, so `minX == maxX` or `minY == maxY`) correctly contain
        /// nothing — no separate empty-rect check is needed, the strict `<` already can't be satisfied. Getting
        /// this wrong is reachable, not theoretical: a marquee that's tapped instead of dragged is exactly a
        /// zero-size rect, and this is the boundary a hit test asks about on every touch.
        public func contains(_ point: CGPoint) -> Bool {
            point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
        }

        /// Whether the two rects overlap, matching real `CGRect.intersects(_:)` — which turns out to have edge
        /// behavior too irregular to fall out of one inequality. Two normal (non-degenerate) rects that merely
        /// share an edge do **not** intersect: `CGRect(x: 60, width: 40).intersects(CGRect(x: 20, width: 40))` is
        /// `false` on real iOS. But a degenerate (zero-width or zero-height) rect touching a normal rect's *min*
        /// edge, or lying strictly inside it, *does* intersect — while touching its *max* edge does not; this
        /// mirrors `contains(_:)`'s min-inclusive/max-exclusive rule applied to the degenerate rect's single
        /// coordinate. Two degenerate rects intersect only when their coordinates coincide exactly. None of this
        /// is documented — it was reverse-engineered by probing real `CGRect` on macOS with dozens of cases
        /// (normal/normal, normal/degenerate in each edge position, degenerate/degenerate, reversed operands,
        /// mixed per-axis combinations); see `Tests/SheetMusicTests/Layout/CGRectNegativeSizeTests.swift`, which
        /// runs the same assertions against the real thing. Computed per axis via `axisOverlaps`, then ANDed.
        public func intersects(_ other: CGRect) -> Bool {
            Self.axisOverlaps(minX, maxX, other.minX, other.maxX)
                && Self.axisOverlaps(minY, maxY, other.minY, other.maxY)
        }

        /// One axis of `intersects(_:)`. `minA == maxA` (equivalently `minB == maxB`) means that operand is
        /// degenerate on this axis — a single coordinate rather than a span.
        private static func axisOverlaps(
            _ minA: CGFloat, _ maxA: CGFloat, _ minB: CGFloat, _ maxB: CGFloat,
        ) -> Bool {
            let degenerateA = minA == maxA
            let degenerateB = minB == maxB
            if !degenerateA, !degenerateB {
                // Both are spans: overlap requires each to extend past the other's start — a shared edge alone
                // (`maxA == minB`) does not count.
                return maxA > minB && maxB > minA
            } else if degenerateA, degenerateB {
                // Both are single coordinates: overlap only when they coincide exactly.
                return minA == minB
            } else if degenerateA {
                // A is a single coordinate, B is a span: contains-style membership — B's min edge counts, B's
                // max edge does not.
                return minB <= minA && minA < maxB
            } else {
                return minA <= minB && minB < maxA
            }
        }

        /// A copy of the rect translated by `(dx, dy)`, matching `CGRect.offsetBy(dx:dy:)`.
        public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
            CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
        }

        /// A copy inset by `dx` on each vertical edge and `dy` on each horizontal one, keeping the same center —
        /// matching `CGRect.insetBy(dx:dy:)`. Negative values GROW the rect, which is the direction every caller
        /// in this package uses it in: a hit test widens an ink box by its tolerance before asking `contains`.
        ///
        /// **One documented divergence, at the far edge of the contract.** Real `CGRectInset` returns the NULL
        /// rect when the inset exceeds half the width or half the height. This stand-in has no null rect to
        /// return — `CGRectNull` is a sentinel with an infinite origin, and this type is a plain struct with no
        /// such value — so it returns the arithmetic result, which is a rect with a negative width or height.
        /// That is not nothing: this type's `minX`/`maxX`/`minY`/`maxY` already normalize a negative-size rect
        /// (see their doc comment), so the result stays coherent for every operation defined here rather than
        /// becoming garbage. But it is NOT what Apple returns, and the difference is observable — a null rect
        /// intersects nothing, while a normalized inverted rect can intersect.
        ///
        /// So `CGRectNegativeSizeTests` deliberately covers only the region where the two agree. Over-insetting
        /// is out of contract, not merely untested: if a future caller needs it, the fix is to give this type a
        /// null representation, not to widen the test around the current behavior.
        public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + dx, y: origin.y + dy,
                width: size.width - dx * 2, height: size.height - dy * 2,
            )
        }

        /// The smallest rect containing both, matching `CGRect.union(_:)`. Computed from the normalized edges,
        /// so a rect built with a negative width or height unions identically to its standardized form.
        ///
        /// **An empty operand is NOT dropped**, which is the part worth stating because the opposite is the
        /// natural guess. A rect with zero width or height still has a position, and real `CGRectUnion`
        /// stretches to reach it: unioning `(0, 0, 10, 10)` with `(100, 100, 0, 0)` gives a rect out to
        /// (100, 100), not the first rect unchanged. Measured against Apple's real `CGRect`, not recalled —
        /// `CGRectNegativeSizeTests` runs that assertion unguarded, so it exercises CoreGraphics on a macOS host
        /// and this stand-in when cross-compiled, and the two are pinned to the same answer.
        ///
        /// The consequence for callers: `union` is not a "bounding box of these rects, skipping the empty ones"
        /// fold. An empty rect in the sequence contributes its origin.
        public func union(_ other: CGRect) -> CGRect {
            let lowerX = min(minX, other.minX)
            let lowerY = min(minY, other.minY)
            let upperX = max(maxX, other.maxX)
            let upperY = max(maxY, other.maxY)
            return CGRect(
                x: lowerX, y: lowerY,
                width: upperX - lowerX, height: upperY - lowerY,
            )
        }
    }

#endif
