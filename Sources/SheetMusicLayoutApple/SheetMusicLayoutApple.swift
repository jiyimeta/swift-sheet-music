import Foundation
import SheetMusicLayout

/// Auto-installable façade for the Apple CoreText backend of
/// `SheetMusicLayout`.
///
/// Touch `SheetMusicLayoutApple.install` (via `_ =
/// SheetMusicLayoutApple.install`) at app launch or in the entry
/// point of any code path that constructs a `LayoutEngine` /
/// `ScoreView` / PDF export. The first touch sets
/// `FontMetrics.provider` to `AppleFontMetricsProvider`; subsequent
/// touches are free (`static let` caches the boolean result).
///
/// `SheetMusicUI` and `SheetMusicPDF` call this in their entry
/// points so Apple host apps don't need to invoke it explicitly.
/// Headless Layout consumers (`RenderPreviews`, isolated Layout
/// tests) call it themselves.
@available(macOS 15.0, *)
public enum SheetMusicLayoutApple {
    public static let install: Bool = {
        FontMetrics.provider = AppleFontMetricsProvider()
        return true
    }()
}
