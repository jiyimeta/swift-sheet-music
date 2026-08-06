#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicMSCX
    import Testing

    /// The host half of SP0/SP1's acceptance test: `EditReplayScript.standard`'s fourteen steps, run through the
    /// same JNI entry points a device calls, with the resulting wire bytes and fingerprints committed as
    /// instrumented-test assets under `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/`.
    /// `EditSessionReplayTest.kt` reads those assets back and replays them on-device via `nativeApplyEditIntent` /
    /// `nativeEditUndo`, asserting the same fifteen fingerprints this test computes.
    ///
    /// Kotlin never builds an intent here, because it never does in production either: the host's Swift core is
    /// always the one that applies an intent to its authoritative score and encodes it, and Kotlin's job is only to
    /// relay the resulting bytes to the mirror session behind the JNI boundary. A Kotlin-authored intent would
    /// exercise a data path that doesn't exist.
    ///
    /// The fixture is `EditingFixtures.replayFixture()` — see its doc comment for its shape — encoded to MSCX and
    /// committed as `editReplay/fixture.mscx`, so both the host and a device parse the exact same bytes. The host
    /// loads its score from that COMMITTED FILE (not straight from the in-memory builder): an encoder change that
    /// silently altered the bytes would otherwise never surface, since the host would just re-derive fresh bytes
    /// that happen to match itself. `EditReplayScript.standard` — the array of steps applied below — is shared with
    /// `EditReplayDeterminismTests`, so this test and that one exercise literally the same edits.
    ///
    /// ## Record vs. verify
    ///
    /// Default (no environment override): **verify**. This test recomputes the wire bytes and fingerprints from the
    /// live `EditIntentCodec` and JNI bridge and compares them against the assets already committed under
    /// `editReplay/` — an inadvertent wire-format or engine-behavior change fails this test on the host, before it
    /// ever reaches a device. This is a regression guard, not just a generator: a generator that silently overwrites
    /// its own expectations every run can never fail.
    ///
    /// Set `SM_EDIT_REPLAY_RECORD=1` to **record**: the freshly computed bytes / fingerprints / fixture encoding
    /// overwrite the committed assets first, and the same comparison then trivially passes. Re-run without the
    /// environment variable afterward to confirm the newly recorded assets are what's about to be committed, and
    /// `git diff` the `editReplay/` directory to review exactly what changed before committing it.
    @Suite("Edit replay goldens")
    struct EditReplayGoldenTests {
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

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

        @Test("replay EditReplayScript.standard and verify (or record) the committed assets")
        func replayMatchesCommittedAssets() throws {
            let dir = assetsDir
            let fixturePath = dir.appendingPathComponent("fixture.mscx")
            let liveFixtureData = try MSCXEncoder.encode(EditingFixtures.replayFixture())

            let isRecording = ProcessInfo.processInfo.environment["SM_EDIT_REPLAY_RECORD"] == "1"
            if isRecording {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try liveFixtureData.write(to: fixturePath)
            }

            // Loaded from the COMMITTED file, not `liveFixtureData` directly — see this type's doc comment on why.
            let fixtureData = try Data(contentsOf: fixturePath)
            let handle = nativeLoadScore(bytes: fixtureData)
            defer { nativeReleaseScore(handle: handle) }
            #expect(handle != 0)
            #expect(nativeBeginEditSession(scoreHandle: handle))

            let steps = EditReplayScript.standard(staff: Self.staff)
            var fingerprints = [nativeScoreFingerprint(scoreHandle: handle)]
            var stepBytes: [Data?] = []
            for step in steps {
                switch step {
                case let .intent(intent):
                    let bytes = EditIntentCodec.encode(intent)
                    stepBytes.append(bytes)
                    #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: bytes))
                case .undo:
                    stepBytes.append(nil)
                    #expect(nativeEditUndo(scoreHandle: handle))
                case .redo:
                    // Defensive only — unreachable from the current script. `EditReplayScript.standard` never emits
                    // this case; see its doc comment on why "redo" is represented as undo-then-reapply instead. The
                    // real `nativeEditRedo` bridge function is covered separately, on the host, by
                    // `EditSessionBridgeTests`. Recorded as a failure rather than silently treated as either an
                    // apply or an undo, since the device-side harness has no asset convention for it.
                    Issue.record("EditReplayStep.redo has no wire representation this harness can commit")
                }
                fingerprints.append(nativeScoreFingerprint(scoreHandle: handle))
            }
            nativeEndEditSession(scoreHandle: handle)
            print("fingerprints: " + fingerprints.map(String.init).joined(separator: ", "))

            #expect(fingerprints.count == steps.count + 1)
            #expect(Set(fingerprints).count >= 10)

            if isRecording {
                try record(stepBytes: stepBytes, fingerprints: fingerprints)
            }
            try verify(stepBytes: stepBytes, fingerprints: fingerprints, liveFixtureData: liveFixtureData)
        }

        /// Overwrites the committed step / golden assets with what this run computed. `fixture.mscx` is already
        /// written by the caller before the score is even loaded — see `replayMatchesCommittedAssets`. Only reached
        /// under `SM_EDIT_REPLAY_RECORD=1` — see the type's doc comment.
        private func record(stepBytes: [Data?], fingerprints: [Int64]) throws {
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
            // Drop any step file left over from a shorter previous script — otherwise a stale step-N.bin from
            // before this task would sit uncommitted-to but still present, and Kotlin would misread it as an edit.
            let stepPrefixedFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in stepPrefixedFiles where name.hasPrefix("step-") && name.hasSuffix(".bin") {
                guard let index = Int(name.dropFirst("step-".count).dropLast(".bin".count)),
                      !stepBytes.indices.contains(index)
                else { continue }
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            let goldens = fingerprints.map(String.init).joined(separator: "\n") + "\n"
            try goldens.write(to: dir.appendingPathComponent("goldens.txt"), atomically: true, encoding: .utf8)
            let stalePath = dir.appendingPathComponent("midi01.mscx")
            if FileManager.default.fileExists(atPath: stalePath.path) {
                try FileManager.default.removeItem(at: stalePath)
            }
            print("recorded \(stepBytes.count) step file(s), goldens.txt, and fixture.mscx under \(dir.path)")
        }

        /// Compares this run's output against whatever is currently on disk under `assetsDir` — the committed
        /// assets on a normal run, or what `record` (plus the caller's own `fixture.mscx` write) just wrote when
        /// `SM_EDIT_REPLAY_RECORD=1`.
        private func verify(stepBytes: [Data?], fingerprints: [Int64], liveFixtureData: Data) throws {
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
            let committedFixture = try Data(contentsOf: dir.appendingPathComponent("fixture.mscx"))
            #expect(
                committedFixture == liveFixtureData,
                "editReplay/fixture.mscx drifted from MSCXEncoder.encode(EditingFixtures.replayFixture())",
            )
        }
    }
#endif
