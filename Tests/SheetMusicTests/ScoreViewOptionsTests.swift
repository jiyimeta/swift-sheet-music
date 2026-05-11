#if os(macOS) || os(iOS)
    import SheetMusicLayout
    import Testing

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
