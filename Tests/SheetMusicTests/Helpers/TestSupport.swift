#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicLayoutApple

    /// Test-suite-side eager installer for the Apple FontMetricsProvider.
    /// Reference `_ = TestSupport.installApple` from any suite that hits
    /// `LayoutEngine.layout(...)` directly (not through UI/PDF).
    /// The static-let chains into `SheetMusicLayoutApple.install`, which
    /// is itself a static-let and so this whole thing is process-wide
    /// idempotent.
    enum TestSupport {
        static let installApple: Bool = {
            if #available(macOS 15.0, *) {
                _ = SheetMusicLayoutApple.install
            }
            return true
        }()
    }
#endif
