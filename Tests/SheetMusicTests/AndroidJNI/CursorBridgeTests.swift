#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Integration tests for the cursor-frame bridge path:
    ///   LayoutDocumentCache → cursorFrame(for:in:) → CursorFrameCodec round-trip.
    struct CursorBridgeTests {
        private let _installApple = TestSupport.installApple

        // MARK: - LayoutDocumentCache

        @Test
        func cacheStoreAndRetrieve() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let handle = Int64(999)

            let result = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: .verticalDefault,
            )
            LayoutDocumentCache.store(
                handle: handle, document: result.document,
                filteredScore: result.filteredScore, hiddenStaves: [],
            )
            defer { LayoutDocumentCache.release(handle) }

            let retrieved = LayoutDocumentCache.value(for: handle)
            #expect(retrieved != nil)
        }

        @Test
        func cacheReleaseRemovesEntry() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let handle = Int64(998)

            let result = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: .verticalDefault,
            )
            LayoutDocumentCache.store(
                handle: handle, document: result.document,
                filteredScore: result.filteredScore, hiddenStaves: [],
            )
            LayoutDocumentCache.release(handle)

            let retrieved = LayoutDocumentCache.value(for: handle)
            #expect(retrieved == nil)
        }

        // MARK: - cursorFrame → CursorFrameCodec round-trip

        @Test
        @available(macOS 15.0, iOS 16.0, *)
        func cursorBridgeReturnsResolvableFrame() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let handle = Int64(1001)

            let result = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: .verticalDefault,
            )
            LayoutDocumentCache.store(
                handle: handle, document: result.document,
                filteredScore: result.filteredScore, hiddenStaves: [],
            )
            defer { LayoutDocumentCache.release(handle) }

            // Build a ScoreCursor.item pointing at the first note in
            // the first chord of the first voice of the first measure.
            let firstStaff = try #require(score.allStaves.first)
            let firstMeasure = try #require(firstStaff.staff.measures.first)
            let firstVoice = try #require(firstMeasure.voices.first)
            // Find the first chord element that has at least one note.
            var firstNoteID: NoteID?
            for (elemIdx, el) in firstVoice.elements.enumerated() {
                if case let .chord(chord) = el, !chord.notes.isEmpty {
                    firstNoteID = NoteID(
                        staff: firstStaff.address,
                        measureIndex: 0,
                        voiceIndex: 0,
                        elementIndex: elemIdx,
                        noteIndexInChord: 0,
                    )
                    break
                }
            }
            let noteID = try #require(firstNoteID)
            let cursor = ScoreCursor.item(.note(noteID))

            // Retrieve from cache (mirrors what nativeCursorFrame does).
            let document = try #require(LayoutDocumentCache.value(for: handle))
            let rect = try #require(document.cursorFrame(for: cursor, in: score))

            // Verify the rect is sensible: positive dimensions.
            #expect(rect.size.width > 0)
            #expect(rect.size.height > 0)

            // Round-trip through CursorFrameCodec.
            // Total byte count varies with TLV varint encoding; round-trip covers correctness.
            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(decoded.x == Double(rect.origin.x))
            #expect(decoded.y == Double(rect.origin.y))
            #expect(decoded.width == Double(rect.size.width))
            #expect(decoded.height == Double(rect.size.height))
        }

        @Test
        @available(macOS 15.0, iOS 16.0, *)
        func beatCursorBridgeRoundTrip() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let handle = Int64(1002)

            let result = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: .verticalDefault,
            )
            LayoutDocumentCache.store(
                handle: handle, document: result.document,
                filteredScore: result.filteredScore, hiddenStaves: [],
            )
            defer { LayoutDocumentCache.release(handle) }

            // Beat cursor at measure 0, tick 0.
            let cursor = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
            let document = try #require(LayoutDocumentCache.value(for: handle))
            let rect = try #require(document.cursorFrame(for: cursor, in: score))

            #expect(rect.size.width > 0)
            #expect(rect.size.height > 0)

            let encoded = CursorFrameCodec.encode(rect)
            let decoded = try #require(try CursorFrameCodec.decode(encoded))
            #expect(abs(decoded.x - Double(rect.origin.x)) < 0.001)
        }
    }
#endif
