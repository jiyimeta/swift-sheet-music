#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicCore
    import Testing

    /// The host half of SP0's acceptance test: ten edit-intent steps, run through the same JNI entry points a
    /// device calls, with the resulting wire bytes and fingerprints committed as instrumented-test assets under
    /// `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/`. `EditSessionReplayTest.kt` reads those assets
    /// back and replays them on-device via `nativeApplyEditIntent` / `nativeEditUndo`, asserting the same eleven
    /// fingerprints this test computes.
    ///
    /// Kotlin never builds an intent here, because it never does in production either: the host's Swift core is
    /// always the one that applies an intent to its authoritative score and encodes it, and Kotlin's job is only to
    /// relay the resulting bytes to the mirror session behind the JNI boundary. A Kotlin-authored intent would
    /// exercise a data path that doesn't exist.
    ///
    /// `midi01.mscx` (`Tests/SheetMusicTests/Resources/midi01.mscx`) has exactly one measure — `KeySig`(0),
    /// `TimeSig`(1), then four quarter-note chords (pitches 60/61♯/62/63♯) at element indices 2-5 — with no rest
    /// anywhere. `.inputNote` requires an existing rest at its target, so every write below is reached by
    /// `.delete`-then-`.inputNote` at the same slot, the pattern `EditSessionBridgeTests.inputNoteAfterDelete`
    /// established. `.setChordDuration` is used on the LAST slot only (element 5), and only ever shortens: the
    /// measure starts completely full (four quarters = one 4/4 bar), so lengthening any slot would consume a
    /// neighbor's ticks, and shortening any slot but the last would insert a new rest between two slots this test
    /// also addresses by fixed index (`DurationChangeAlgorithm`) — either would shift the very indices later steps
    /// rely on. Shortening the last slot only appends a trailing rest at a new, otherwise-untouched index (6).
    ///
    /// Steps 7 and 8 (0-indexed) repeat that same last-slot-only trick twice more, each time shortening the rest the
    /// previous step just appended and letting the remainder spill into a fresh trailing index — never touching
    /// indices 2-5, which every earlier step still addresses by fixed position. That covers the two shapes the
    /// original eight steps missed: `.setRestDuration` (step 7 — never exercised before) and `.inputNote` with a
    /// non-`nil` duration (step 8's composite, the only path that writes a populated `NoteDurationWire` instead of
    /// the `hasDuration == 0` placeholder). Step 8's `SetRestDuration` sub-command is a genuine shortening (sixteenth
    /// to thirty-second), not the wire-round-trip's degenerate same-duration case, so it actually exercises
    /// `DurationChangeAlgorithm`'s shortening branch rather than the `srcTicks == dstTicks` early return.
    ///
    /// ## Record vs. verify
    ///
    /// Default (no environment override): **verify**. This test recomputes the wire bytes and fingerprints from the
    /// live `EditIntentCodec` and JNI bridge and compares them against the assets already committed under
    /// `editReplay/` — an inadvertent wire-format or engine-behavior change fails this test on the host, before it
    /// ever reaches a device. This is a regression guard, not just a generator: a generator that silently overwrites
    /// its own expectations every run can never fail.
    ///
    /// Set `SM_EDIT_REPLAY_RECORD=1` to **record**: the freshly computed bytes / fingerprints / fixture copy
    /// overwrite the committed assets first, and the same comparison then trivially passes. Re-run without the
    /// environment variable afterward to confirm the newly recorded assets are what's about to be committed, and
    /// `git diff` the `editReplay/` directory to review exactly what changed before committing it.
    @Suite("Edit replay goldens")
    struct EditReplayGoldenTests {
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func rest(_ measure: Int, _ element: Int) -> RestID {
            RestID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
        }

        private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
            VoiceElementID(rest(measure, element))
        }

        /// The ten steps, in order. `nil` means undo — see `replayMatchesCommittedAssets`. This array is the
        /// single source of truth for both the wire bytes this test writes/verifies under `editReplay/` and the
        /// fingerprints in `goldens.txt`; `EditSessionReplayTest.kt` never re-derives an intent, it only replays
        /// what this array produced.
        static let steps: [EditIntent?] = [
            .delete(at: slot(0, 2)),
            .inputNote(at: rest(0, 2), pitch: 67, tpc: 15, duration: nil),
            .delete(at: slot(0, 3)),
            nil,
            .composite([
                .delete(at: slot(0, 4)),
                .inputNote(at: rest(0, 4), pitch: 64, tpc: 18, duration: nil),
            ]),
            nil,
            .setChordDuration(at: slot(0, 5), duration: .eighth),
            // Steps 7-8: `.setRestDuration` (never exercised above) and `.inputNote` with a non-nil duration (the
            // only path that writes a populated `NoteDurationWire`) — see this type's doc comment for why these
            // land here, at the tail, rather than disturbing the fixed indices 2-5 rely on.
            .setRestDuration(at: slot(0, 6), duration: .sixteenth),
            .inputNote(at: rest(0, 7), pitch: 72, tpc: 14, duration: .thirtySecond),
            .inputNote(at: rest(0, 6), pitch: 69, tpc: 21, duration: nil),
        ]

        /// `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/`, resolved via `#filePath` so it is
        /// correct regardless of the process's current directory — unlike a path relative to wherever `swift test`
        /// happens to have been invoked from.
        private var assetsDir: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // AndroidJNI
                .deletingLastPathComponent() // SheetMusicTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // package root
                .appendingPathComponent("Android/SheetMusicAndroid/src/androidTest/assets/editReplay")
        }

        @Test("replay the eight steps and verify (or record) the committed assets")
        func replayMatchesCommittedAssets() throws {
            let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
            let fixtureData = try Data(contentsOf: url)
            let handle = nativeLoadScore(bytes: fixtureData)
            defer { nativeReleaseScore(handle: handle) }
            #expect(handle != 0)
            #expect(nativeBeginEditSession(scoreHandle: handle))

            var fingerprints = [nativeScoreFingerprint(scoreHandle: handle)]
            var stepBytes: [Data?] = []
            for step in Self.steps {
                if let step {
                    let bytes = EditIntentCodec.encode(step)
                    stepBytes.append(bytes)
                    #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: bytes))
                } else {
                    stepBytes.append(nil)
                    #expect(nativeEditUndo(scoreHandle: handle))
                }
                fingerprints.append(nativeScoreFingerprint(scoreHandle: handle))
            }
            nativeEndEditSession(scoreHandle: handle)
            print("fingerprints: " + fingerprints.map(String.init).joined(separator: ", "))

            #expect(fingerprints.count == 11)
            #expect(Set(fingerprints).count >= 5)

            if ProcessInfo.processInfo.environment["SM_EDIT_REPLAY_RECORD"] == "1" {
                try record(stepBytes: stepBytes, fingerprints: fingerprints, fixtureData: fixtureData)
            }
            try verify(stepBytes: stepBytes, fingerprints: fingerprints, fixtureData: fixtureData)
        }

        /// Overwrites the committed assets with what this run computed. Only reached under
        /// `SM_EDIT_REPLAY_RECORD=1` — see the type's doc comment.
        private func record(stepBytes: [Data?], fingerprints: [Int64], fixtureData: Data) throws {
            let dir = assetsDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (index, bytes) in stepBytes.enumerated() {
                let path = dir.appendingPathComponent("step-\(index).bin")
                if let bytes {
                    try bytes.write(to: path)
                } else if FileManager.default.fileExists(atPath: path.path) {
                    // A step that used to be an edit and is now an undo — drop the stale file so "no file" keeps
                    // meaning "undo" on the Kotlin side (see EditSessionReplayTest.kt's loop).
                    try FileManager.default.removeItem(at: path)
                }
            }
            let goldens = fingerprints.map(String.init).joined(separator: "\n") + "\n"
            try goldens.write(to: dir.appendingPathComponent("goldens.txt"), atomically: true, encoding: .utf8)
            try fixtureData.write(to: dir.appendingPathComponent("midi01.mscx"))
            print("recorded \(stepBytes.count) step file(s), goldens.txt, and midi01.mscx under \(dir.path)")
        }

        /// Compares this run's output against whatever is currently on disk under `assetsDir` — the committed
        /// assets on a normal run, or what `record` just wrote when `SM_EDIT_REPLAY_RECORD=1`.
        private func verify(stepBytes: [Data?], fingerprints: [Int64], fixtureData: Data) throws {
            let dir = assetsDir
            for (index, bytes) in stepBytes.enumerated() {
                let path = dir.appendingPathComponent("step-\(index).bin")
                if let bytes {
                    let committed = try Data(contentsOf: path)
                    #expect(committed == bytes, "step-\(index).bin drifted from the live EditIntentCodec output")
                } else {
                    #expect(
                        !FileManager.default.fileExists(atPath: path.path),
                        "step-\(index).bin exists but step \(index) is an undo — remove it or fix the step",
                    )
                }
            }
            let goldensText = try String(contentsOf: dir.appendingPathComponent("goldens.txt"), encoding: .utf8)
            let committedFingerprints = goldensText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { Int64($0) }
            #expect(committedFingerprints == fingerprints, "goldens.txt drifted from the live fingerprints")
            let committedFixture = try Data(contentsOf: dir.appendingPathComponent("midi01.mscx"))
            #expect(committedFixture == fixtureData, "editReplay/midi01.mscx drifted from the Resources fixture")
        }
    }
#endif
