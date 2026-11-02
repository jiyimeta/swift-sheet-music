#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import Testing

        /// Tables of a track's own read through a stretcher (`setPlaybackAlignment(warp:segments:trackSegments:)`):
        /// which tracks share a group, and which changes restart one. Against `FakeStretcher`, with the suite's
        /// helpers.
        extension AudioEngineSerial.RecordingStretcherRenderTests {
            /// A stretcher is fed its group's input against one target timeline, so two tracks at one transposition but
            /// on different tables cannot share it. Stem B's table starts it at warped second 0.5, 0.714 s in at 70 %:
            /// before that only stem A sounds.
            @Test("tracks with different tables take separate stretch groups")
            func differentTablesTakeSeparateGroups() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                let stems = try Self.stems(a: 0, b: 0)
                rig.backend.setRecordingTracks(stems.tracks)
                rig.backend.setPlaybackAlignment(warp: nil, segments: [], trackSegments: [
                    "a": Fixtures.wholeRecording(4),
                    "b": [RecordingSegment(sourceStart: 0, sourceEnd: 4, outputStart: 0.5)],
                ])
                rig.backend.play()
                let samples = try rig.render(seconds: 1)

                #expect(recorder.made.count == 4, "a pair for each table")
                let alone = samples[Fixtures.frame(0.6)]
                let both = samples[Fixtures.frame(0.9)]
                #expect(abs(alone - 0.1) < 0.005, "A alone before B's table starts: \(alone)")
                #expect(abs(both - 0.4) < 0.005, "A + B after: \(both)")
            }

            /// Both stems on one table share its pair, and follow the table rather than the shared one: silent until
            /// warped second 0.5, 0.714 s in at 70 %.
            @Test("tracks with identical tables share one group")
            func identicalTablesShareOneGroup() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                let stems = try Self.stems(a: 0, b: 0)
                let table = [RecordingSegment(sourceStart: 0, sourceEnd: 4, outputStart: 0.5)]
                rig.backend.setRecordingTracks(stems.tracks)
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: Fixtures.wholeRecording(4), trackSegments: ["a": table, "b": table],
                )
                rig.backend.play()
                let samples = try rig.render(seconds: 1)

                #expect(recorder.made.count == 2, "one pair for both")
                let before = samples[..<Fixtures.frame(0.7)].map(abs).max() ?? 1
                let both = samples[Fixtures.frame(0.9)]
                #expect(before < 1e-6, "before the table starts: \(before)")
                #expect(abs(both - 0.4) < 0.005, "A + B after: \(both)")
            }

            /// The new table plays the same file second where the transport is (it only ends sooner), so the target
            /// does not move: only the restart a new table asks for re-primes the group, on the idle instance, and the
            /// change is crossfaded.
            @Test("changing a track's table restarts its group")
            func tableChangeRestartsTheGroup() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                let level = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { _ in 16384 }
                rig.backend.setRecordingTracks([RecordingTrackRender(id: "take", recording: level)])
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: [], trackSegments: ["take": Fixtures.wholeRecording(4)],
                )
                rig.backend.play()
                let before = try rig.render(seconds: 0.5)
                try #require(recorder.made.count == 2)
                #expect(recorder.made[0].seeks.isEmpty, "the first stream plays on the second instance")
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: [], trackSegments: ["take": Fixtures.wholeRecording(3)],
                )
                let after = try rig.render(seconds: 0.3)

                #expect(recorder.made.count == 2, "the group keeps its pair")
                let seek = Call.seek(frames: recorder.made[0].seekLength(rate: Self.rate70), rate: Self.rate70)
                #expect(recorder.made[0].calls.prefix(3) == [.reset, .transpose(0), seek], "restarted, retuned")
                let around = Array(before.suffix(100)) + after
                let largestStep = zip(around.dropFirst(), around).map { abs($0 - $1) }.max() ?? 1
                #expect(largestStep < 0.01, "largest step between frames: \(largestStep)")
                #expect(abs((after.last ?? 0) - 0.5) < 0.01, "after: \(after.last ?? 0)")
            }

            /// A table of a track's own is in the file's seconds, so the track's offset is not applied and its
            /// stretcher is fed the same input whatever the offset says. A new offset therefore must not restart the
            /// group: the idle instance of the pair is never touched, and the file is still read at the table's second.
            @Test("an offset change on a track with its own table does not restart its stretch group")
            func offsetChangeOnAnOwnTableKeepsTheGroup() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                // 0.6 for the first second, 0.2 after it.
                let steps = try Fixtures.recording(rate: 44100, frames: 44100 * 4) { $0 < 44100 ? 19661 : 6554 }
                rig.backend.setRecordingTracks([RecordingTrackRender(id: "take", recording: steps)])
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: [], trackSegments: ["take": Fixtures.wholeRecording(4)],
                )
                rig.backend.play()
                // 1.5 s at 70 % reads the file at 1.05 s: 0.2.
                let before = try rig.render(seconds: 1.5)
                // Applied, this offset would read the file half a second earlier, at 0.6.
                rig.backend.setRecordingTracks([
                    RecordingTrackRender(id: "take", recording: steps, offsetSeconds: 0.5),
                ])
                let after = try rig.render(seconds: 0.3)

                try #require(recorder.made.count == 2, "the group keeps its pair")
                #expect(recorder.made[0].calls.isEmpty, "the idle instance was never restarted")
                let around = Array(before.suffix(100)) + after
                let largestStep = zip(around.dropFirst(), around).map { abs($0 - $1) }.max() ?? 1
                #expect(largestStep < 0.01, "largest step between frames: \(largestStep)")
                #expect(abs((before.last ?? 0) - 0.2) < 0.01, "before: \(before.last ?? 0)")
                #expect(abs((after.last ?? 0) - 0.2) < 0.01, "after, still at the table's second: \(after.last ?? 0)")
            }

            /// Stem A plays the shared table and stem B a table of its own, so they are two groups. B's new table plays
            /// the same second where the transport is: its own group restarts, and A's group, whose table, tracks and
            /// files are as they were, carries on untouched.
            @Test("changing another track's table does not restart a group with no table")
            func anotherTracksTableLeavesTheSharedGroup() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                let stems = try Self.stems(a: 0, b: 0)
                rig.backend.setRecordingTracks(stems.tracks)
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: Fixtures.wholeRecording(4), trackSegments: ["b": Fixtures.wholeRecording(4)],
                )
                rig.backend.play()
                let before = try rig.render(seconds: 0.5)
                try #require(recorder.made.count == 4, "a pair for the shared table, then one for B's")
                rig.backend.setPlaybackAlignment(
                    warp: nil, segments: Fixtures.wholeRecording(4), trackSegments: ["b": Fixtures.wholeRecording(3)],
                )
                let after = try rig.render(seconds: 0.3)

                #expect(recorder.made.count == 4, "no new pair")
                let seek = Call.seek(frames: recorder.made[2].seekLength(rate: Self.rate70), rate: Self.rate70)
                #expect(recorder.made[2].calls.prefix(3) == [.reset, .transpose(0), seek], "B's group restarted")
                #expect(recorder.made[0].calls.isEmpty, "A's group, on the shared table, was not restarted")
                let level = Self.range(Array(before[Self.fadeFrames...]) + after)
                #expect(level.lowest > 0.395 && level.highest < 0.405, "A + B across the change: \(level)")
            }
        }
    #endif
#endif
