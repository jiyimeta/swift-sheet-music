#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicMSCX
    import Testing

    /// The bridge could read five formats and write none of them, so an Android host that edited a
    /// score through `nativeApplyEditIntent` had nowhere to put the result — the edit lived in a
    /// process-local handle and died with it. `SheetMusicMSCX` cross-compiles to Android and has
    /// written `.mscx` / `.mscz` all along; only the JNI surface was missing.
    struct ScoreEncodeBridgeTests {
        private func loadFixture() throws -> Score {
            let url = try #require(TestResources.url(
                forResource: "midi01",
                withExtension: "mscx",
            ))
            return try ScoreBridge.loadScore(bytes: Data(contentsOf: url))
        }

        /// The contract `MSCXEncoder` states for itself — a *semantic* round trip — carried across
        /// the bridge. Fingerprints rather than `==` because `stableFingerprint` is what the edit
        /// bridge already uses to decide two images agree, so a divergence here is the same
        /// divergence a host would act on.
        @Test
        func mscxRoundTripsThroughTheBridge() throws {
            let score = try loadFixture()
            let bytes = try ScoreEncodeBridge.encode(score, format: .mscx)
            let reloaded = try ScoreBridge.loadScore(bytes: bytes)
            #expect(reloaded.stableFingerprint == score.stableFingerprint)
        }

        /// `.mscz` is a ZIP, and `ScoreLoader.sniff` routes on the local-file-header magic, so an
        /// archive that does not start with it would be sniffed as `.unknown` and refused on the way
        /// back in — the failure would look like a parser bug rather than a writer one.
        @Test
        func msczCarriesTheZipMagicAndRoundTrips() throws {
            let score = try loadFixture()
            let bytes = try ScoreEncodeBridge.encode(score, format: .mscz)
            #expect(Array(bytes.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
            let reloaded = try ScoreBridge.loadScore(bytes: bytes)
            #expect(reloaded.stableFingerprint == score.stableFingerprint)
        }

        /// The MS3-compatibility target is a documented `MSCXEncoderOptions` feature
        /// (`README.md`'s MSCX row names it); a bridge that silently always wrote MS4 would take it
        /// away from every Android host.
        @Test
        func targetVersionSelectsTheMuseScore3Writer() throws {
            let score = try loadFixture()
            let v3 = try ScoreEncodeBridge.encode(score, format: .mscx, targetVersion: .v3)
            let v4 = try ScoreEncodeBridge.encode(score, format: .mscx, targetVersion: .v4)
            let v3Text = try #require(String(data: v3, encoding: .utf8))
            let v4Text = try #require(String(data: v4, encoding: .utf8))
            #expect(v3Text.contains("version=\"3.02\""))
            #expect(v4Text.contains("version=\"4.60\""))
        }

        /// `.v2` is detection-only on `MSCXVersion`; `MSCXEncoderOptions` normalizes it to `.v3` at
        /// construction. Pinned here because the bridge takes the version as an `Int32` off the wire,
        /// where a host can plausibly send 2.
        @Test
        func museScore2NormalizesToMuseScore3() throws {
            let score = try loadFixture()
            let bytes = try ScoreEncodeBridge.encode(score, format: .mscx, targetVersion: .v2)
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(text.contains("version=\"3.02\""))
        }

        /// Preserved markup is source fidelity rather than a semantic guarantee, so a host preparing
        /// an edited score for distribution has to be able to drop it — the same escape hatch
        /// `MSCXEncoderOptions.emitPreservedMarkup` gives an Apple host.
        @Test
        func preservedMarkupCanBeSuppressed() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01",
                withExtension: "mscx",
            ))
            let score = try ScoreBridge.loadScore(bytes: Data(contentsOf: url))
            let kept = try ScoreEncodeBridge.encode(score, format: .mscx, emitPreservedMarkup: true)
            let dropped = try ScoreEncodeBridge.encode(
                score, format: .mscx, emitPreservedMarkup: false,
            )
            // Equal only when the fixture carries no preserved markup at all; the assertion that
            // matters is that the flag reaches the encoder, which a size difference or an equal
            // pair both satisfy. What must not happen is the flag being ignored in a way that
            // changes the *other* direction, so compare against the encoder called directly.
            var suppressing = MSCXEncoderOptions(targetVersion: .v4)
            suppressing.emitPreservedMarkup = false
            let expectedDropped = try MSCXEncoder.encode(score, options: suppressing)
            let expectedKept = try MSCXEncoder.encode(
                score, options: MSCXEncoderOptions(targetVersion: .v4),
            )
            #expect(dropped == expectedDropped)
            #expect(kept == expectedKept)
        }

        // MARK: - JNI entry point

        /// The entry point's own contract: an unknown handle is an empty `Data`, matching every
        /// other `native*` in this bridge rather than trapping.
        @Test
        func nativeEncodeReturnsEmptyForAnUnknownHandle() {
            let bytes = nativeEncodeScore(
                scoreHandle: 0, format: 0, targetVersion: 0, emitPreservedMarkup: 1,
            )
            #expect(bytes.isEmpty)
        }

        /// An out-of-range format is a host bug, and answering it with bytes in *some* format would
        /// hand the host a file with the wrong extension. Empty is the honest answer.
        @Test
        func nativeEncodeReturnsEmptyForAnUnknownFormat() throws {
            let score = try loadFixture()
            let handle = scoreTable.insert(score)
            defer { scoreTable.release(handle) }
            #expect(nativeEncodeScore(
                scoreHandle: handle, format: 99, targetVersion: 0, emitPreservedMarkup: 1,
            ).isEmpty)
        }

        @Test
        func nativeEncodeProducesReloadableBytes() throws {
            let score = try loadFixture()
            let handle = scoreTable.insert(score)
            defer { scoreTable.release(handle) }
            for format in Int32(0) ... 1 {
                let bytes = nativeEncodeScore(
                    scoreHandle: handle, format: format, targetVersion: 0, emitPreservedMarkup: 1,
                )
                #expect(!bytes.isEmpty)
                let reloaded = try ScoreBridge.loadScore(bytes: bytes)
                #expect(reloaded.stableFingerprint == score.stableFingerprint)
            }
        }

        /// `0` means "the encoder's own default" so a Kotlin host that has no opinion does not have
        /// to know which MuseScore version this library targets.
        @Test
        func nativeEncodeTreatsZeroTargetVersionAsTheDefault() throws {
            let score = try loadFixture()
            let handle = scoreTable.insert(score)
            defer { scoreTable.release(handle) }
            let implicit = nativeEncodeScore(
                scoreHandle: handle, format: 0, targetVersion: 0, emitPreservedMarkup: 1,
            )
            let explicit = nativeEncodeScore(
                scoreHandle: handle, format: 0, targetVersion: 4, emitPreservedMarkup: 1,
            )
            #expect(implicit == explicit)
            #expect(!implicit.isEmpty)
        }
    }
#endif
