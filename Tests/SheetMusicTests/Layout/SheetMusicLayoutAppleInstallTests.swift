#if !os(Android)
    import Foundation
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    @Suite("SheetMusicLayoutApple.install")
    struct SheetMusicLayoutAppleInstallTests {
        // NOTE: do NOT reassign `FontMetrics.provider` from these tests.
        // Swift Testing runs suites in parallel; mutating the global
        // mid-test races with layout-running suites that read it
        // (LayoutCacheTests, LayoutBracketTests, etc.) and causes
        // intermittent measurement-drift failures.

        @available(macOS 15.0, *)
        @Test func installSwapsProviderToApple() {
            // Touching install is idempotent — first touch (anywhere in
            // the process) sets provider to Apple; subsequent touches
            // hit the cached `true`. Either way the post-state is Apple.
            _ = SheetMusicLayoutApple.install
            #expect(FontMetrics.provider is AppleFontMetricsProvider)
        }

        @available(macOS 15.0, *)
        @Test func installIsIdempotent() {
            _ = SheetMusicLayoutApple.install
            let first = type(of: FontMetrics.provider)
            _ = SheetMusicLayoutApple.install
            let second = type(of: FontMetrics.provider)
            #expect(String(describing: first) == String(describing: second))
        }
    }
#endif
