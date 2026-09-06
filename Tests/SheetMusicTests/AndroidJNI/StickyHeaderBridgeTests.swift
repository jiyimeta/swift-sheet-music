#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// MuseScore's continuous view freezes the current clef, key signature, time signature and
    /// instrument name at the viewport's left edge, so a reader who has scrolled past bar 1 can
    /// still see what key and metre they are in. `SheetMusicUI.StickyHeaderView` does that on
    /// Apple; no other host could, because the pane is a *synthesized* system rather than a slice
    /// of the score, and nothing bridged the synthesis.
    @Suite("StickyHeaderBridge")
    struct StickyHeaderBridgeTests {
        private let _installApple = TestSupport.installApple

        /// Four measures on one staff. Bar 1 is 4/4 in C; bar 3 changes to 3/4 and two sharps, so
        /// a scroll position inside bar 3 must show something a scroll position inside bar 1 does
        /// not — which is the entire point of the pane.
        private static func score() -> Score {
            func measure(_ elements: [VoiceElement]) -> Measure {
                Measure(voices: [Voice(elements: elements)])
            }
            let quarter = VoiceElement.chord(
                Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]),
            )
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "flute"),
                    staves: [Staff(measures: [
                        measure([.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                            + Array(repeating: quarter, count: 4)),
                        measure(Array(repeating: quarter, count: 4)),
                        measure([
                            .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
                            .keySignature(KeySignature(concertKey: 2)),
                        ] + Array(repeating: quarter, count: 3)),
                        measure(Array(repeating: quarter, count: 3)),
                    ])],
                )],
            )
        }

        /// Insert, lay out horizontally (the mode a sticky header exists for), return the handle.
        private static func laidOutHandle() -> Int64 {
            let handle = scoreTable.insert(score())
            var options = LayoutOptionsWire.verticalDefault
            options.layoutMode = 1 // horizontal — one long system
            _ = nativeComputeLayout(
                scoreHandle: handle,
                pageWidthMM: 210,
                pageHeightMM: 297,
                optionsBlob: options.encodeToData(),
            )
            return handle
        }

        private static func release(_ handle: Int64) {
            LayoutDocumentCache.release(handle)
            scoreTable.release(handle)
        }

        private static func page(_ data: Data) throws -> EncodablePage {
            let pages = try DrawProgramCodec.decode(data)
            #expect(pages.count == 1)
            return try #require(pages.first)
        }

        @Test
        func aHeaderPaneIsProducedAtTheStartOfTheScore() throws {
            let handle = Self.laidOutHandle()
            defer { Self.release(handle) }
            let page = try Self.page(nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: 0))
            #expect(page.widthMM > 0)
            #expect(page.heightMM > 0)
            #expect(!page.commands.isEmpty)
        }

        /// The pane must answer for the measure the reader is looking at, not the one they started
        /// from. Bar 3 changes both the time signature and the key, so its pane cannot be the same
        /// commands as bar 1's — if it is, the scroll position never reached the synthesis.
        @Test
        func thePaneFollowsTheScrollPosition() throws {
            let handle = Self.laidOutHandle()
            defer { Self.release(handle) }
            let entry = try #require(LayoutDocumentCache.entry(for: handle))
            let system = try #require(entry.document.systems.first)
            let thirdBar = try #require(system.measures.first { $0.measureIndex == 2 })
            // Document points → mm, the inverse of the entry point's own conversion.
            let ptToMM = 25.4 / 72.0
            let scrollMm = Double(system.origin.x + thirdBar.origin.x + thirdBar.width / 2) * ptToMM

            let atStart = try Self.page(
                nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: 0),
            )
            let atThirdBar = try Self.page(
                nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: scrollMm),
            )
            #expect(atStart.commands != atThirdBar.commands)
        }

        /// Scrolling past the end clamps rather than emptying. A header that vanishes at the end of
        /// a score is worse than one that stops changing — the reader loses the key signature
        /// exactly where a long final passage makes it hardest to remember.
        @Test
        func scrollingPastTheEndClampsToTheLastMeasure() throws {
            let handle = Self.laidOutHandle()
            defer { Self.release(handle) }
            let page = try Self.page(
                nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: 100_000),
            )
            #expect(!page.commands.isEmpty)
        }

        /// "No answer" is empty `Data`, matching every other geometry entry point — and it is not
        /// what a legitimate-but-empty pane looks like.
        @Test
        func anUnknownHandleAnswersWithNoData() {
            #expect(nativeStickyHeaderProgram(scoreHandle: 0, scrollXMm: 0).isEmpty)
        }

        @Test
        func aScoreWithNoCachedLayoutAnswersWithNoData() {
            let handle = scoreTable.insert(Self.score())
            defer { scoreTable.release(handle) }
            #expect(nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: 0).isEmpty)
        }

        /// The pane is a page of the ordinary draw program, so a host paints it with the renderer it
        /// already has. Asserted by decoding it through the same codec `nativeComputeLayout`'s
        /// output goes through — a second wire shape here would mean a second drawing path on every
        /// consumer.
        @Test
        func thePaneDecodesAsAnOrdinaryDrawProgram() throws {
            let handle = Self.laidOutHandle()
            defer { Self.release(handle) }
            let data = nativeStickyHeaderProgram(scoreHandle: handle, scrollXMm: 0)
            #expect(throws: Never.self) { try DrawProgramCodec.decode(data) }
        }
    }
#endif
