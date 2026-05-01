#if os(macOS)
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("StemDirectionRule")
    struct StemDirectionTests {
        @Test("Single note below middle line → stem up")
        func belowMiddle() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [-3]) == .up)
        }

        @Test("Single note above middle line → stem down")
        func aboveMiddle() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [3]) == .down)
        }

        @Test("Single note on middle line → stem up (tie-break lower)")
        func onMiddle() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [0]) == .up)
        }

        @Test("Chord with median 0 → stem up")
        func chordMedianZero() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [-2, 0, 2]) == .up)
        }

        @Test("Chord [0, 3] median 1.5 → stem down")
        func chordMedianOnePointFive() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [0, 3]) == .down)
        }

        @Test("Chord [1, 2] median 1.5 → stem down")
        func chordMedianPositive() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: [1, 2]) == .down)
        }

        @Test("Empty input → up default")
        func emptyDefault() {
            guard #available(macOS 15.0, *) else { return }
            #expect(StemDirectionRule.direction(for: []) == .up)
        }
    }
#endif
