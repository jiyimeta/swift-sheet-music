#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    /// `nativePageBreaks` paginates the cached document a second time, so it has to resolve the break policy the
    /// way `nativeComputeLayout` did — through `LayoutOptionsWire.breakPolicy`. It once read an older boolean
    /// instead, so a host asking for `.ignoreSystemBreaks` without that boolean set was told about one page while
    /// the draw program honored the authored page break and drew two.
    @Suite("nativePageBreaks")
    struct PageBreaksBridgeTests {
        private let _installApple = TestSupport.installApple

        /// Three whole-note bars, the middle one carrying an authored page break — the Android twin of the wasm
        /// suite's `SampleScore.pageBreakScore()`.
        private static func pageBreakScore() -> Score {
            let measures = (0 ..< 3).map { index in
                Measure(
                    voices: [Voice(elements: [
                        .chord(Chord(duration: .whole, notes: [Note(pitch: 60 + index, tpc: 14)])),
                    ])],
                    pageBreak: index == 1,
                )
            }
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
        }

        /// The count header of a `PageBreaksWire` payload: one entry per page boundary plus the content bottom,
        /// so `pageCount + 1`. `nil` for a payload too short to carry one.
        private static func boundaryCount(_ data: Data) -> Int? {
            guard data.count >= 4 else { return nil }
            return Int(data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }

        /// A page height no three-bar score fills, so only the authored page break can start a second page.
        /// `2` (`.ignoreSystemBreaks`) is the row this suite exists for: it still honors `page`, so it must
        /// paginate like `.honor`, not like `.ignoreAll`.
        @Test(arguments: [(UInt8(0), 3), (1, 3), (2, 3), (3, 2)])
        func pageBoundariesFollowTheResolvedBreakPolicy(breakPolicyRaw: UInt8, expectedBoundaries: Int) {
            let handle = scoreTable.insert(Self.pageBreakScore())
            defer { LayoutDocumentCache.release(handle); scoreTable.release(handle) }
            var wire = LayoutOptionsWire.verticalDefault
            wire.breakPolicyRaw = breakPolicyRaw
            let options = wire.encodeToData()
            let program = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: options,
            )
            #expect(!program.isEmpty)

            let result = nativePageBreaks(scoreHandle: handle, pageHeightMM: 10000, optionsBytes: options)
            #expect(Self.boundaryCount(result) == expectedBoundaries)
        }
    }
#endif
