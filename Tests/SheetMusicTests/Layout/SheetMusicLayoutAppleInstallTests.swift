#if !os(Android)
    import Foundation
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    @Suite("SheetMusicLayoutApple.install", .serialized)
    struct SheetMusicLayoutAppleInstallTests {
        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
        @Test func installSwapsProviderToApple() {
            // Reset state so the test is meaningful regardless of order.
            FontMetrics.provider = StubFontMetricsProvider()
            _ = SheetMusicLayoutApple.install
            #expect(FontMetrics.provider is AppleFontMetricsProvider)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
        @Test func installIsIdempotent() {
            FontMetrics.provider = StubFontMetricsProvider()
            _ = SheetMusicLayoutApple.install
            let first = type(of: FontMetrics.provider)
            // Second touch: the static let returns its cached value, no
            // additional swap happens. If someone reassigned provider in
            // the meantime, install does NOT clobber it (that is by
            // design — second touch is a no-op).
            _ = SheetMusicLayoutApple.install
            let second = type(of: FontMetrics.provider)
            #expect(String(describing: first) == String(describing: second))
        }
    }
#endif
