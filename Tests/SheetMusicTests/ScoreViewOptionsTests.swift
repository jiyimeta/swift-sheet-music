@testable import SheetMusicLayout
import Testing

#if os(macOS) || os(iOS)
    @Suite("ScoreViewOptions multiMeasureRest")
    struct ScoreViewOptionsMultiMeasureRestTests {
        @Test("default is .disabled")
        func defaultDisabled() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let opts = ScoreViewOptions()
            #expect(opts.multiMeasureRest == .disabled)
        }

        @Test("collapse case carries minimum")
        func collapseCarriesMinimum() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let opts = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 4),
            )
            if case let .collapse(min) = opts.multiMeasureRest {
                #expect(min == 4)
            } else {
                Issue.record("expected .collapse")
            }
        }
    }
#endif

/// Outside the os() guard on purpose: unlike multiMeasureRest, this option
/// exists on every platform shape, and the file it was merged from
/// (ShowsInvisibleOptionTests.swift) compiled unguarded.
@Suite("ScoreViewOptions showsInvisibleElements")
struct ScoreViewOptionsShowsInvisibleTests {
    @Test func defaultsToFalse() {
        #expect(ScoreViewOptions().showsInvisibleElements == false)
    }

    @Test func canEnable() {
        var opts = ScoreViewOptions()
        opts.showsInvisibleElements = true
        #expect(opts.showsInvisibleElements == true)
    }
}
