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
}
