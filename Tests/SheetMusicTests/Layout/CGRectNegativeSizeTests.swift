#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicLayout
import Testing

/// Covers `CGRect.contains`/`intersects` against a rect built with negative width/height — e.g. a marquee dragged
/// bottom-right → top-left before being standardized. `minX`/`maxX`/`minY`/`maxY` normalize to the min/max of each
/// edge on both platforms (`CGRectGetMinX` et al. on Apple; the stand-in in
/// `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift` on Android), so a reversed rect must answer identically
/// to its standardized form. This suite is unguarded on purpose: the same assertions exercise Apple's real
/// `CGRect` on a macOS/iOS host and the Android stand-in when cross-compiled, which is the strongest evidence the
/// two agree — a platform-specific guard would only let one of them prove anything.
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

    @Test("contains(_:) matches the standardized rect for an interior point, an edge point, and an exterior point")
    func containsMatchesStandardized() {
        let inside = CGPoint(x: 80, y: 85)
        let onEdge = CGPoint(x: 60, y: 70)
        let outside = CGPoint(x: 200, y: 200)

        #expect(reversed.contains(inside) && standardized.contains(inside))
        #expect(reversed.contains(onEdge) && standardized.contains(onEdge))
        #expect(!reversed.contains(outside) && !standardized.contains(outside))
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
}
