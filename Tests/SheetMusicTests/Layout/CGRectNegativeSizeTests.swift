#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicLayout
import Testing

/// Covers `CGRect.contains`/`intersects` against a rect built with negative width/height — e.g. a marquee dragged
/// bottom-right → top-left before being standardized — and against the min-inclusive/max-exclusive edge rule and
/// the empty-rect case (a marquee that's tapped, not dragged) that distinguish a stub that actually matches
/// `CGRectContainsPoint`/`CGRectIntersectsRect` from one that merely looks like it does. `minX`/`maxX`/`minY`/
/// `maxY` normalize to the min/max of each edge on both platforms (`CGRectGetMinX` et al. on Apple; the stand-in
/// in `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift` on Android), so a reversed rect must answer
/// identically to its standardized form. This suite is unguarded on purpose: the same assertions exercise Apple's
/// real `CGRect` on a macOS/iOS host and the Android stand-in when cross-compiled, which is the strongest
/// evidence the two agree — a platform-specific guard would only let one of them prove anything.
///
/// Deliberately does **not** `import Foundation`: on Android, `Foundation` (swift-corelibs-foundation) ships its
/// own complete `CGFloat`/`CGPoint`/`CGSize`/`CGRect` — including its own `intersects`/`contains`/`offsetBy` — and
/// a file that imports both `Foundation` and `SheetMusicLayout` silently resolves unqualified `CGRect` to
/// Foundation's type instead of this module's, with no compiler diagnostic. That would make this suite validate
/// Foundation's implementation instead of `CGTypes+Android.swift`'s. See the warning atop that file.
@Suite("CGRect — reversed (negative-size) rect")
struct CGRectNegativeSizeTests {
    // Built bottom-right → top-left: negative width and height.
    private let reversed = CGRect(x: 100, y: 100, width: -40, height: -30)
    private let standardized = CGRect(x: 60, y: 70, width: 40, height: 30)

    @Test("minX/maxX/minY/maxY normalize regardless of sign")
    func normalizedAccessors() {
        #expect(reversed.minX == standardized.minX)
        #expect(reversed.maxX == standardized.maxX)
        #expect(reversed.minY == standardized.minY)
        #expect(reversed.maxY == standardized.maxY)
    }

    @Test("contains(_:) matches the standardized rect for an interior, exterior, and each-edge point")
    func containsMatchesStandardized() {
        let inside = CGPoint(x: 80, y: 85)
        let outside = CGPoint(x: 200, y: 200)
        // min-inclusive: a point on the top-left (min-X, min-Y) corner is contained.
        let minEdge = CGPoint(x: 60, y: 70)
        // max-exclusive: points exactly on the right edge or the bottom edge are *not* contained, even though
        // they sit on the rect's own boundary — `CGRectContainsPoint` draws this line at `< maxX` / `< maxY`,
        // not `<= maxX` / `<= maxY`.
        let onRightEdge = CGPoint(x: 100, y: 85)
        let onBottomEdge = CGPoint(x: 80, y: 100)

        #expect(reversed.contains(inside) && standardized.contains(inside))
        #expect(!reversed.contains(outside) && !standardized.contains(outside))
        #expect(reversed.contains(minEdge) && standardized.contains(minEdge))
        #expect(!reversed.contains(onRightEdge) && !standardized.contains(onRightEdge))
        #expect(!reversed.contains(onBottomEdge) && !standardized.contains(onBottomEdge))
    }

    @Test("An empty (zero-width or zero-height) rect contains no point, including one on its own degenerate line")
    func emptyRectContainsNothing() {
        // A marquee that's tapped rather than dragged produces exactly this shape: zero width, non-zero height.
        let zeroWidth = CGRect(x: 10, y: 10, width: 0, height: 10)
        let onItsLine = CGPoint(x: 10, y: 15)
        #expect(!zeroWidth.contains(onItsLine))

        let zeroHeight = CGRect(x: 10, y: 10, width: 10, height: 0)
        #expect(!zeroHeight.contains(CGPoint(x: 15, y: 10)))
    }

    @Test("intersects(_:) matches the standardized rect for an overlapping, a disjoint, and a merely-touching rect")
    func intersectsMatchesStandardized() {
        let overlapping = CGRect(x: 50, y: 60, width: 20, height: 20)
        let disjoint = CGRect(x: 1000, y: 1000, width: 10, height: 10)
        // Shares only the x = 60 edge with `standardized` — a touching pair, not an overlapping one.
        let merelyTouching = CGRect(x: 20, y: 70, width: 40, height: 30)

        #expect(reversed.intersects(overlapping) && standardized.intersects(overlapping))
        #expect(!reversed.intersects(disjoint) && !standardized.intersects(disjoint))
        #expect(!reversed.intersects(merelyTouching) && !standardized.intersects(merelyTouching))
    }

    /// A degenerate (zero-width/height) operand does *not* uniformly make `intersects` false — real `CGRect`'s
    /// edge behavior here is irregular enough that "empty rects never intersect" is a plausible-sounding rule
    /// that's simply wrong. It follows `contains(_:)`'s min-inclusive/max-exclusive convention: a degenerate rect
    /// touching a normal rect's min edge, or lying strictly inside it, intersects; touching the max edge, or
    /// lying outside, does not. Two degenerate rects intersect only when they coincide exactly. Every case here
    /// was verified against real `CGRect` on macOS before being written down (see `CGTypes+Android.swift`'s
    /// `intersects` doc comment) — this suite is what keeps that true on both platforms rather than just once.
    @Test("intersects(_:) with a degenerate operand follows contains(_:)'s min-inclusive/max-exclusive rule")
    func intersectsWithDegenerateOperand() {
        let normal = CGRect(x: 0, y: 0, width: 20, height: 20)

        let strictlyInside = CGRect(x: 10, y: 5, width: 0, height: 10)
        #expect(normal.intersects(strictlyInside) && strictlyInside.intersects(normal))

        let onMinEdge = CGRect(x: 0, y: 5, width: 0, height: 10)
        #expect(normal.intersects(onMinEdge) && onMinEdge.intersects(normal))

        let onMaxEdge = CGRect(x: 20, y: 5, width: 0, height: 10)
        #expect(!normal.intersects(onMaxEdge) && !onMaxEdge.intersects(normal))

        let outside = CGRect(x: 30, y: 5, width: 0, height: 10)
        #expect(!normal.intersects(outside) && !outside.intersects(normal))

        let coincidingPoint = CGRect(x: 5, y: 5, width: 0, height: 0)
        #expect(normal.intersects(coincidingPoint) && coincidingPoint.intersects(normal))

        let samePoint = CGRect(x: 5, y: 5, width: 0, height: 0)
        let otherPoint = CGRect(x: 50, y: 50, width: 0, height: 0)
        #expect(samePoint.intersects(CGRect(x: 5, y: 5, width: 0, height: 0)))
        #expect(!samePoint.intersects(otherPoint))
    }

    /// `insetBy(dx:dy:)` in the direction the package actually uses it: a NEGATIVE inset, which grows the rect.
    /// `ScoreHitTester+Text` widens a text's ink box by the hit tolerance before asking `contains`, so getting
    /// the sign backwards would silently shrink every text hit target instead of padding it.
    ///
    /// The positive direction is covered too, but only within half the extent. Past that, real `CGRectInset`
    /// returns the null rect and the stand-in cannot — that divergence is documented on `insetBy` and is out of
    /// contract, so asserting it here would pin a disagreement rather than an agreement.
    @Test("insetBy(dx:dy:) grows on a negative inset and shrinks on a positive one, about the same center")
    func insetByMatchesCoreGraphics() {
        let rect = CGRect(x: 10, y: 20, width: 40, height: 30)

        let grown = rect.insetBy(dx: -5, dy: -3)
        #expect(grown.minX == 5)
        #expect(grown.minY == 17)
        #expect(grown.maxX == 55)
        #expect(grown.maxY == 53)

        let shrunk = rect.insetBy(dx: 5, dy: 3)
        #expect(shrunk.minX == 15)
        #expect(shrunk.minY == 23)
        #expect(shrunk.maxX == 45)
        #expect(shrunk.maxY == 47)

        // The center is what an inset preserves; it is the property that makes the sign convention memorable.
        #expect(grown.midX == rect.midX && grown.midY == rect.midY)
        #expect(shrunk.midX == rect.midX && shrunk.midY == rect.midY)

        // A reversed rect insets identically to its standardized form, because both read through the
        // normalizing accessors rather than through `origin`/`size` in declaration order.
        #expect(reversed.insetBy(dx: -5, dy: -5).midX == standardized.insetBy(dx: -5, dy: -5).midX)
    }

    /// `union(_:)` on two ordinary rects, on a reversed one, and — the case that is a real question rather than
    /// arithmetic — on an EMPTY one.
    ///
    /// A zero-size rect still has a position. Whether `CGRectUnion` stretches to include that position or drops
    /// the rect entirely is exactly the kind of edge behavior `intersects(_:)` was already caught guessing at.
    /// This assertion runs unguarded against Apple's real `CGRect` as well as against the stand-in, so it is the
    /// real CoreGraphics answer that both are pinned to — not anyone's recollection of the documentation.
    ///
    /// `ScoreHitTester+Text` seeds its box from the first ink rect and unions the rest, so it never passes an
    /// empty one today. That is why this needs stating rather than why it does not.
    @Test("union(_:) returns the smallest rect containing both, including when one is empty")
    func unionMatchesCoreGraphics() {
        let left = CGRect(x: 0, y: 0, width: 10, height: 10)
        let right = CGRect(x: 20, y: 5, width: 10, height: 10)

        let both = left.union(right)
        #expect(both.minX == 0)
        #expect(both.minY == 0)
        #expect(both.maxX == 30)
        #expect(both.maxY == 15)

        // Commutative, and unaffected by how either operand was built.
        #expect(right.union(left).minX == both.minX && right.union(left).maxX == both.maxX)
        #expect(reversed.union(standardized).minX == standardized.minX)
        #expect(reversed.union(standardized).maxY == standardized.maxY)

        // Union with itself is itself.
        #expect(left.union(left).minX == left.minX && left.union(left).maxY == left.maxY)

        // The empty operand, and the answer measured rather than recalled: real `CGRectUnion` does NOT drop a
        // zero-size rect. It has a position, and the union stretches to reach it — so this returns a rect from
        // (0, 0) to (100, 100), not `left` unchanged. Anyone reaching for `union` as a "bounding box of these
        // rects, skipping the empty ones" fold will silently include an empty rect's origin; that is what
        // CoreGraphics does and therefore what the stand-in must do.
        let emptyOutside = CGRect(x: 100, y: 100, width: 0, height: 0)
        let withEmpty = left.union(emptyOutside)
        #expect(withEmpty.maxX == 100)
        #expect(withEmpty.maxY == 100)
    }
}
