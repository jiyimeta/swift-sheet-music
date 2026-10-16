#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if canImport(CoreGraphics)
        import CoreGraphics
    #endif
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicMSCX
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

        // MARK: - Frames

        private static let ptToMM = 25.4 / 72

        /// Three whole-note bars and a ten-spatium box after the last one.
        private static func trailingFrameScore() -> Score {
            let measures = (0 ..< 3).map { index in
                Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60 + index, tpc: 14)])),
                ])])
            }
            let box = ScoreFrame(heightSp: 10, texts: [], autoSize: false)
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
                blocks: [PositionedScoreBlock(beforeMeasureIndex: 3, block: .verticalFrame(box))],
            )
        }

        /// The offsets of a `PageBreaksWire` payload, in millimetres.
        private static func offsets(_ data: Data) -> [Double] {
            let bytes = [UInt8](data)
            return stride(from: 4, to: bytes.count - 7, by: 8).map { start in
                Double(bitPattern: bytes[start ..< start + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            }
        }

        /// `.page` options: wrapped, with the title block, cut into pages.
        private static func pageOptions(breakPolicyRaw: UInt8 = 0) -> LayoutOptionsWire {
            var wire = LayoutOptionsWire.verticalDefault
            wire.layoutMode = LayoutOptionsWire.Mode.page.rawValue
            wire.breakPolicyRaw = breakPolicyRaw
            return wire
        }

        /// Vertical options with a 6 sp bottom margin, so the document's height is not where its content ends.
        private static func marginedOptions() -> Data {
            var wire = LayoutOptionsWire.verticalDefault
            wire.spacing = EngravingSpacingWire(marginBottom: 6)
            return wire.encodeToData()
        }

        /// `score` laid out by `nativeComputeLayout` with `options`, then its page breaks on a page `pageHeightMM`
        /// tall, or — with `nil` — on one a point taller than the last system's bottom.
        private static func breaks(
            of score: Score, options: Data, pageHeightMM: Double? = nil,
        ) throws -> (document: LayoutDocument, offsets: [Double]) {
            let handle = scoreTable.insert(score)
            defer { LayoutDocumentCache.release(handle); scoreTable.release(handle) }
            _ = nativeComputeLayout(scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: options)
            let document = try #require(LayoutDocumentCache.value(for: handle))
            let last = try #require(document.systems.last)
            let height = pageHeightMM ?? Double(last.origin.y + last.size.height + 1) * ptToMM
            let data = nativePageBreaks(scoreHandle: handle, pageHeightMM: height, optionsBytes: options)
            return (document, offsets(data))
        }

        /// Every system fits on one page and the box under the last one does not, so it gets a page of its own, which
        /// ends at the box's bottom — the content's end, not the document's, whose height adds the bottom margin.
        @Test func framesOnlyLastPageEndsAtTheContentBottom() throws {
            let result = try Self.breaks(of: Self.trailingFrameScore(), options: Self.marginedOptions())
            let box = try #require(result.document.frames.last)
            try #require(result.document.size.height > box.bottom, "the bottom margin must be below the box")
            #expect(result.offsets.count == 3)
            #expect(abs((result.offsets.last ?? 0) - Double(box.bottom) * Self.ptToMM) < 1e-6)
        }

        /// A score without frames reports exactly the offsets it always did: the systems-only cut, ending at the last
        /// system's bottom however large the bottom margin.
        @Test func framelessOffsetsAreUnchanged() throws {
            let result = try Self.breaks(
                of: Self.pageBreakScore(), options: Self.marginedOptions(), pageHeightMM: 10000,
            )
            let document = result.document
            let mmToPt = 72.0 / 25.4
            let ranges = LayoutPaginator.paginate(
                systems: document.systems, pageHeight: CGFloat(10000 * mmToPt), policy: .honor,
            )
            let tops = ranges.map { range -> Double in
                guard range.lowerBound > 0 else { return 0 }
                let previous = document.systems[range.lowerBound - 1]
                return Double(previous.origin.y + previous.size.height) / mmToPt
            }
            let last = try #require(document.systems.last)
            #expect(document.frames.isEmpty)
            #expect(result.offsets == tops + [Double(last.origin.y + last.size.height) / mmToPt])
        }

        /// `.page` mode draws a page per `document.paginate` range. On a page no music fills, frames-boxes still takes
        /// two: VBox B's page break ends the first.
        @Test func pageModeDrawsAPagePerRange() throws {
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
            let wire = Self.pageOptions()
            let laidOut = LayoutBridge.computePages(score: score, pageWidthMM: 210, pageHeightMM: 2000, options: wire)
            let ranges = laidOut.document.paginate(pageHeight: CGFloat(2000 / Self.ptToMM), policy: wire.breakPolicy)
            #expect(laidOut.pages.count == ranges.count)
            #expect(ranges.count == 2)
        }

        /// Page 1 is drawn from a document that keeps the title block, the title's picture and the frames on it.
        @Test func firstPageCarriesTheTitleAndItsFrames() throws {
            let score = try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
            let wire = Self.pageOptions(breakPolicyRaw: 3)
            let document = LayoutBridge.computePages(
                score: score, pageWidthMM: 210, pageHeightMM: 2000, options: wire,
            ).document
            let ranges = LayoutBridge.pageRanges(document: document, options: wire, pageHeightMM: 2000, margins: .zero)
            try #require(ranges.count == 1)
            let first = LayoutBridge.pageDocument(0, of: ranges, in: document)
            #expect(first.titleFrame == document.titleFrame)
            #expect(first.titleImages.count == 1)
            #expect(first.titleImages == document.titleImages)
            #expect(first.frames.count == 1)
            #expect(first.frames == document.frames)
        }
    }
#endif
