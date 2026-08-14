#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI

    // `LayoutDocumentCache` and `LayoutOptionsWire` moved here when the bridge split; the `native*`
    // entry points this drives stayed in SheetMusicAndroidJNI.
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    import SheetMusicEditWire
    import Testing

    /// The stale-layout guard.
    ///
    /// `nativeComputeLayout` reads the score at its start and files the resulting document at its end, without the
    /// edit lock — so an edit landing in between leaves a document describing a score that no longer exists, filed
    /// against a handle whose score is new. Nothing downstream can tell: the fingerprint check compares *scores*,
    /// not layouts, and `nativeEditingHitTest` answers straight out of this cache with an ID the host then edits.
    ///
    /// The race itself is a thread interleaving, which a test cannot pin deterministically. Its two halves can be,
    /// and their composition is the race: an applied intent advances the handle's generation, and a store carrying
    /// a superseded generation is refused. The third test guards the other direction — that an ordinary compute,
    /// with nothing intervening, still files — because a stamp that never matched would "fix" the race by breaking
    /// the cache outright, and every geometry test in `EditGeometryBridgeTests` would still pass (they store
    /// documents directly, without a stamp).
    @Suite("LayoutDocumentCache generation")
    struct LayoutCacheGenerationTests {
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        /// `midi01.mscx` measure 0, element 2 — a quarter chord. Retiming an existing chord needs no rest to
        /// target, unlike `.inputNote`; see `EditSessionBridgeTests.chordSlot`.
        private static let chordSlot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

        private static func loadedHandle() throws -> Int64 {
            let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
            let handle = try nativeLoadScore(bytes: Data(contentsOf: url))
            #expect(handle != 0)
            return handle
        }

        private static func computeLayout(_ handle: Int64) -> Data {
            nativeComputeLayout(
                scoreHandle: handle,
                pageWidthMM: 210,
                pageHeightMM: 297,
                optionsBlob: LayoutOptionsWire.verticalDefault.encodeToData(),
            )
        }

        @Test("an ordinary compute files its layout")
        func computeFilesItsLayout() throws {
            let handle = try Self.loadedHandle()
            defer { nativeReleaseScore(handle: handle) }

            #expect(!Self.computeLayout(handle).isEmpty)
            #expect(LayoutDocumentCache.entry(for: handle) != nil)
        }

        @Test("an applied intent advances the handle's generation")
        func applyAdvancesGeneration() throws {
            let handle = try Self.loadedHandle()
            defer { nativeReleaseScore(handle: handle) }
            #expect(nativeBeginEditSession(scoreHandle: handle))
            defer { nativeEndEditSession(scoreHandle: handle) }

            let before = LayoutDocumentCache.scoreGeneration(for: handle)
            let intent = EditIntent.setChordDuration(at: Self.chordSlot, duration: .eighth)
            #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)))

            #expect(LayoutDocumentCache.scoreGeneration(for: handle) != before)
        }

        /// The half that closes the race: a document computed against generation N cannot be filed once the score
        /// has moved to N+1, so the cache stays EMPTY rather than stale and the next hit test answers "nothing"
        /// instead of naming an element the user did not tap.
        @Test("a layout stamped before an edit is refused, and the cache stays empty")
        func staleLayoutIsRefused() throws {
            let handle = try Self.loadedHandle()
            defer { nativeReleaseScore(handle: handle) }
            #expect(nativeBeginEditSession(scoreHandle: handle))
            defer { nativeEndEditSession(scoreHandle: handle) }

            // Stand in for a compute that has read the score and produced a document but not yet filed it.
            let stamp = LayoutDocumentCache.scoreGeneration(for: handle)
            #expect(!Self.computeLayout(handle).isEmpty)
            let document = try #require(LayoutDocumentCache.entry(for: handle))

            // The edit overtakes it: `publish` replaces the score and invalidates the cache.
            let intent = EditIntent.setChordDuration(at: Self.chordSlot, duration: .eighth)
            #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)))
            #expect(LayoutDocumentCache.entry(for: handle) == nil)

            // The compute now files. It must not land.
            let stored = LayoutDocumentCache.store(
                handle: handle,
                document: document.document,
                filteredScore: document.filteredScore,
                hiddenStaves: document.hiddenStaves,
                options: document.options,
                pageWidthMM: document.pageWidthMM,
                pageHeightMM: document.pageHeightMM,
                computedFromGeneration: stamp,
            )

            #expect(!stored)
            #expect(LayoutDocumentCache.entry(for: handle) == nil)
        }

        /// A released handle's generation goes with it, so a recycled id starts clean — and a compute still in
        /// flight against the freed score finds a generation that no longer matches and declines to file.
        @Test("releasing a handle forgets its generation")
        func releaseForgetsGeneration() throws {
            let handle = try Self.loadedHandle()
            #expect(nativeBeginEditSession(scoreHandle: handle))
            let intent = EditIntent.setChordDuration(at: Self.chordSlot, duration: .eighth)
            #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)))
            #expect(LayoutDocumentCache.scoreGeneration(for: handle) != 0)

            nativeEndEditSession(scoreHandle: handle)
            nativeReleaseScore(handle: handle)

            #expect(LayoutDocumentCache.scoreGeneration(for: handle) == 0)
        }
    }
#endif
