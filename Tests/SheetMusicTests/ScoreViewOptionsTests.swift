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

@Suite("ScoreViewOptions fixedLayoutWidth")
struct ScoreViewOptionsFixedLayoutWidthTests {
    @Test func defaultsToNil() {
        #expect(ScoreViewOptions().fixedLayoutWidth == nil)
    }

    @Test func initTakesItInFinalPosition() {
        let opts = ScoreViewOptions(staffSize: 18, fixedLayoutWidth: 612)
        #expect(opts.fixedLayoutWidth == 612)
        // The other fields keep their defaults — the new parameter is
        // appended, not inserted.
        #expect(opts.staffSize == 18)
        #expect(opts.lyricsVisible == true)
    }

    @Test func equatableDistinguishesTheField() {
        var a = ScoreViewOptions()
        var b = ScoreViewOptions()
        #expect(a == b)
        a.fixedLayoutWidth = 800
        #expect(a != b)
        b.fixedLayoutWidth = 800
        #expect(a == b)
        // nil and 0 are different states, not the same "unset".
        b.fixedLayoutWidth = 0
        #expect(a != b)
    }
}
