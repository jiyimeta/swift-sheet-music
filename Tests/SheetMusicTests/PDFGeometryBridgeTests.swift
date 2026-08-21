#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Exercises the JNI entry points as plain Swift functions — the same thing Kotlin calls.
    ///
    /// Two groups of tests here, deliberately:
    ///
    /// - The `fixtureData()`-based tests (handle lifecycle, page sizes) parse a real PDF produced by the
    ///   production exporter and cover the parse → handle → release path end to end.
    /// - The cursor-rect and hit-test tests build a `PDFScoreGeometry` by hand instead of parsing one.
    ///   `PDFSwiftReaderEntryTests.fixtureData()`'s notation never populates `itemRects` / `noteRects`:
    ///   `emitShow` only decodes 2-byte CID glyph codes, and the fixture's CoreText-drawn text uses a
    ///   1-byte simple font, so no glyph geometry is ever recorded for it (a pre-existing, out-of-scope
    ///   gap — see that file's `fixtureData()` doc comment). Without any `itemRects`, neither a `.item`
    ///   cursor nor a `.beat` cursor (which anchors on decoded note columns) can resolve against that
    ///   fixture, so a hand-built geometry is the only way to exercise the flip / lookup / encode logic
    ///   this task actually owns.
    @MainActor struct PDFGeometryBridgeTests {
        @Test func loadReturnsTwoLiveHandles() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let result = try PdfParseResultWire(decoding: nativeLoadScoreWithGeometryFromPDF(bytes: Self.fixtureData()))
            #expect(result.scoreHandle != 0)
            #expect(result.geometryHandle != 0)
            nativeReleasePdfGeometry(handle: result.geometryHandle)
            nativeReleaseScore(handle: result.scoreHandle)
        }

        @Test func loadReturnsEmptyForNonPDFBytes() {
            #expect(nativeLoadScoreWithGeometryFromPDF(bytes: Data("nope".utf8)).isEmpty)
        }

        /// A structurally-valid-but-empty parse must be distinguishable from a real one. The fixture decodes
        /// no notes (its 1-byte simple font is the pre-existing `emitShow` gap), which is exactly the shape a
        /// Chrome "print to PDF" produces: staff lines and measure cells, zero elements. A host that only
        /// checks "did the parse throw" would offer the user a silent transport.
        @Test func parseResultReportsHowManyElementsWereReconstructed() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let result = try PdfParseResultWire(decoding: nativeLoadScoreWithGeometryFromPDF(bytes: Self.fixtureData()))
            defer {
                nativeReleasePdfGeometry(handle: result.geometryHandle)
                nativeReleaseScore(handle: result.scoreHandle)
            }
            #expect(result.playableElementCount == 0)
        }

        /// The counter's floor: a score with no staves reports nothing rather than trapping.
        @Test func playableElementCountIsZeroForAnEmptyScore() {
            #expect(playableElementCount(of: Score(division: 480, parts: [])) == 0)
        }

        /// Only sounding content counts. The importer emits clef / key / time elements from a state machine
        /// that never inspects a notehead, so counting `voice.elements` wholesale would report a page whose
        /// clef classified but whose noteheads did not as playable — putting a host back on "enabled
        /// transport, one second, silence". Rests are excluded for the same reason.
        @Test func onlyNoteBearingChordsAreCounted() {
            let clefOnly = Self.score(elements: [.clef(Clef(concertClefType: "F"))])
            #expect(playableElementCount(of: clefOnly) == 0)

            let restOnly = Self.score(elements: [.chord(Chord(duration: .whole, notes: []))])
            #expect(playableElementCount(of: restOnly) == 0)

            let withNote = Self.score(elements: [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            ])
            #expect(playableElementCount(of: withNote) == 1)
        }

        /// One staff, one measure, one voice holding `elements`.
        private static func score(elements: [VoiceElement]) -> Score {
            Score(
                division: 480,
                parts: [
                    Part(
                        id: "P1",
                        instrument: Instrument(id: "piano", articulations: []),
                        staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
                    ),
                ],
            )
        }

        @Test func pageSizesMatchTheDocument() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let result = try PdfParseResultWire(decoding: nativeLoadScoreWithGeometryFromPDF(bytes: Self.fixtureData()))
            defer {
                nativeReleasePdfGeometry(handle: result.geometryHandle)
                nativeReleaseScore(handle: result.scoreHandle)
            }
            let sizes = try PdfPageSizesWire(decoding: nativePdfPageSizes(geometryHandle: result.geometryHandle))
            #expect(!sizes.widths.isEmpty)
            #expect(sizes.widths.count == sizes.heights.count)
            #expect(sizes.widths.allSatisfy { $0 > 0 })
        }

        @Test func releasedGeometryStopsResolving() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let result = try PdfParseResultWire(decoding: nativeLoadScoreWithGeometryFromPDF(bytes: Self.fixtureData()))
            nativeReleasePdfGeometry(handle: result.geometryHandle)
            nativeReleaseScore(handle: result.scoreHandle)
            #expect(nativePdfPageSizes(geometryHandle: result.geometryHandle).isEmpty)
        }

        @Test func cursorRectIsEmptyForAnUnknownHandle() {
            let cursor = ScoreCursorCodec.encode(.beat(measureIndex: 0, tickInMeasure: 0))
            #expect(nativePdfCursorRect(geometryHandle: 987_654, cursorBytes: cursor).isEmpty)
        }

        /// The rect returned by `entry.geometry.cursorRect(for:in:)` is PDF user space (y-up); the wire
        /// must come out flipped into top-left, y-down page space. Every number here is picked so the
        /// expected flip is exact arithmetic, not just "some rect came back".
        @Test func cursorRectFlipsIntoTopLeftPageSpace() throws {
            let synthetic = Self.makeSyntheticGeometry()
            defer { pdfGeometryTable.release(synthetic.handle) }
            let rect = try PdfRectWire(decoding: nativePdfCursorRect(
                geometryHandle: synthetic.handle,
                cursorBytes: ScoreCursorCodec.encode(.item(synthetic.itemID)),
            ))
            // Pre-flip (PDF, y-up): the item's column (x:100...120) grown to the system's y-range
            // (150...350) → CGRect(x: 100, y: 150, width: 20, height: 200). Flipped for a page height of
            // 800: y becomes pageHeight - rect.maxY == 800 - 350 == 450.
            #expect(rect.pageIndex == 0)
            #expect(rect.x == 100)
            #expect(rect.y == 450)
            #expect(rect.width == 20)
            #expect(rect.height == 200)
        }

        /// A tap at the cursor rect's own centre must resolve back to a cursor pointing at the same
        /// item — the round trip the reader relies on. The centre lands inside the measure cell but
        /// outside the note's own onset rect, so this exercises `hitTest`'s cell fallback, not just a
        /// direct notehead hit.
        @Test func hitTestResolvesTheCursorRectCentreBackToTheSameItem() throws {
            let synthetic = Self.makeSyntheticGeometry()
            defer { pdfGeometryTable.release(synthetic.handle) }
            let rect = try PdfRectWire(decoding: nativePdfCursorRect(
                geometryHandle: synthetic.handle,
                cursorBytes: ScoreCursorCodec.encode(.item(synthetic.itemID)),
            ))
            let hit = nativePdfHitTest(
                geometryHandle: synthetic.handle,
                pageIndex: rect.pageIndex,
                x: rect.x + rect.width / 2,
                y: rect.y + rect.height / 2,
            )
            #expect(!hit.isEmpty)
            #expect(try ScoreCursorCodec.decode(hit) == .item(synthetic.itemID))
        }

        /// A tap outside every measure cell must miss cleanly instead of falling back to something.
        ///
        /// Despite the name this predecessor test had, it does not exercise `nearestNote`/`nearestRest`'s
        /// distance-tolerance branch: `makeSyntheticGeometry()` leaves `noteRects` empty and its one
        /// `itemRects` entry is a `.note`, not a `.rest`, so both loops have zero candidates to measure a
        /// distance to and return `nil` unconditionally, regardless of the tap point or `tolerance`. What
        /// this actually covers is `leadingItemOfMeasure`'s cell-containment check declining a point
        /// outside every `measureRects` cell.
        @Test func hitTestReturnsEmptyOutsideEveryMeasureCell() {
            let synthetic = Self.makeSyntheticGeometry()
            defer { pdfGeometryTable.release(synthetic.handle) }
            let hit = nativePdfHitTest(geometryHandle: synthetic.handle, pageIndex: 0, x: 590, y: 10)
            #expect(hit.isEmpty)
        }

        // MARK: - Fixtures

        /// Reuses `PDFSwiftReaderEntryTests`'s exporter-produced fixture rather than adding a third copy.
        @available(macOS 15.0, iOS 16.0, *)
        static func fixtureData() throws -> Data {
            try PDFSwiftReaderEntryTests.fixtureData()
        }

        /// A hand-built geometry with exactly one item, sized so the arithmetic in the tests above is
        /// exact: one `itemRects` entry (a note's onset column), one `systemRects` entry that vertically
        /// contains it (grows the column into a full-height cursor bar), one `measureRects` cell (the
        /// hit-test fallback for a tap that lands in the bar but off the note itself), and one page size.
        static func makeSyntheticGeometry() -> (handle: Int64, itemID: ScoreItemID) {
            let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            let noteID = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
            let itemID = ScoreItemID.note(noteID)
            let geometry = PDFScoreGeometry(
                itemRects: [
                    itemID: PDFElementRect(pageIndex: 0, rect: CGRect(x: 100, y: 200, width: 20, height: 10)),
                ],
                measureRects: [
                    PDFScoreGeometry.MeasureCellKey(staff: staff, measureIndex: 0):
                        PDFElementRect(pageIndex: 0, rect: CGRect(x: 90, y: 150, width: 40, height: 200)),
                ],
                systemRects: [
                    PDFElementRect(pageIndex: 0, rect: CGRect(x: 0, y: 150, width: 500, height: 200)),
                ],
                pageSizes: [0: CGSize(width: 600, height: 800)],
            )
            let entry = PDFGeometryEntry(score: Score(division: 480), geometry: geometry)
            return (pdfGeometryTable.insert(entry), itemID)
        }
    }
#endif
