#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicLayout
    import Testing

    /// `ScoreHitTester.itemIDs(in:)` — the rubber-band query the Apple example drags a marquee with —
    /// lives in `SheetMusicLayout` and has cross-compiled to Android since that target existed. It
    /// just had no JNI entry point, so an Android host could select exactly one thing at a time.
    ///
    /// Drives the entry point the same way `EditGeometryBridgeTests` drives its neighbours: a
    /// hand-built `Score` inserted into `scoreTable`, then `nativeComputeLayout` to populate
    /// `LayoutDocumentCache`, then the entry point itself.
    @Suite("MarqueeBridge")
    struct MarqueeBridgeTests {
        private let _installApple = TestSupport.installApple

        /// One measure, 4/4: a quarter chord followed by three quarter rests — five event columns
        /// whose x positions the marquee can cut between.
        private static func noteScore() -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// Insert `score`, lay it out, and return the handle. The caller releases it.
        private static func laidOutHandle(_ score: Score) -> Int64 {
            let handle = scoreTable.insert(score)
            _ = nativeComputeLayout(
                scoreHandle: handle,
                pageWidthMM: 210,
                pageHeightMM: 297,
                optionsBlob: LayoutOptionsWire.verticalDefault.encodeToData(),
            )
            return handle
        }

        private static func release(_ handle: Int64) {
            LayoutDocumentCache.release(handle)
            scoreTable.release(handle)
        }

        /// A rect covering the whole page finds every chord and rest the score has. Four elements:
        /// the chord plus three rests — the time signature is not a selectable item.
        @Test
        func aRectOverTheWholePageFindsEveryChordAndRest() throws {
            let handle = Self.laidOutHandle(Self.noteScore())
            defer { Self.release(handle) }
            let ids = try ScoreItemIDListCodec.decode(
                nativeItemIDsInRect(
                    scoreHandle: handle, xMm: 0, yMm: 0, widthMm: 210, heightMm: 297,
                ),
            )
            #expect(ids.count == 4)
        }

        /// A rect the layout does not reach answers with a decodable empty list, not empty `Data`.
        /// The two mean different things — "nothing is there" versus "I could not answer" — and a
        /// host that cannot tell them apart will show a stale selection for a released handle.
        @Test
        func aRectOverNothingIsAnEmptyListRatherThanNoAnswer() throws {
            let handle = Self.laidOutHandle(Self.noteScore())
            defer { Self.release(handle) }
            let payload = nativeItemIDsInRect(
                scoreHandle: handle, xMm: 190, yMm: 280, widthMm: 5, heightMm: 5,
            )
            #expect(!payload.isEmpty)
            #expect(try ScoreItemIDListCodec.decode(payload).isEmpty)
        }

        /// Empty `Data` is reserved for "no answer": an unknown handle.
        @Test
        func anUnknownHandleAnswersWithNoData() {
            #expect(nativeItemIDsInRect(
                scoreHandle: 0, xMm: 0, yMm: 0, widthMm: 210, heightMm: 297,
            ).isEmpty)
        }

        /// A layout that was never computed is the other "no answer" case — the same guard
        /// `nativeEditingHitTest` has, since both read `LayoutDocumentCache`.
        @Test
        func aScoreWithNoCachedLayoutAnswersWithNoData() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle) }
            #expect(nativeItemIDsInRect(
                scoreHandle: handle, xMm: 0, yMm: 0, widthMm: 210, heightMm: 297,
            ).isEmpty)
        }

        /// The order is part of the contract: systems top-to-bottom, then event columns
        /// left-to-right. A host naming "the first thing the drag covered", or extending a selection
        /// with the keyboard, reads it — which is why the payload is a list and not a set.
        @Test
        func resultsComeBackInLeftToRightQueryOrder() throws {
            let handle = Self.laidOutHandle(Self.noteScore())
            defer { Self.release(handle) }
            let ids = try ScoreItemIDListCodec.decode(
                nativeItemIDsInRect(
                    scoreHandle: handle, xMm: 0, yMm: 0, widthMm: 210, heightMm: 297,
                ),
            )
            // The chord is element index 1 and the rests 2…4, laid out in that order along x.
            let elementIndices = ids.map(\.elementIndex)
            #expect(elementIndices == elementIndices.sorted())
        }

        /// The ids are full-score-addressed, matching `nativeEditingHitTest`, so a host can hand
        /// this result straight to `nativeEncodeDrawProgram` without re-addressing anything. Pinned
        /// by round-tripping the marquee's own answer back through the tint encoder.
        @Test
        func idsAreAcceptedByTheSelectionTintEncoder() throws {
            let handle = Self.laidOutHandle(Self.noteScore())
            defer { Self.release(handle) }
            let ids = try ScoreItemIDListCodec.decode(
                nativeItemIDsInRect(
                    scoreHandle: handle, xMm: 0, yMm: 0, widthMm: 210, heightMm: 297,
                ),
            )
            let tinted = nativeEncodeDrawProgram(
                scoreHandle: handle,
                selectionBytes: SelectionTintCodec.encode(argb: 0xFFAB_CDEF, ids: Set(ids)),
            )
            let untinted = nativeEncodeDrawProgram(
                scoreHandle: handle,
                selectionBytes: SelectionTintCodec.encode(argb: 0xFFAB_CDEF, ids: []),
            )
            #expect(!tinted.isEmpty)
            // A selection the encoder actually applied changes the program; an empty one reproduces
            // `nativeComputeLayout`'s bytes. Equal programs would mean the ids were silently dropped
            // on the way in — the exact failure a mismatched address space produces.
            #expect(tinted != untinted)
        }
    }
#endif
