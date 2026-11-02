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

            /// A host dragging a track's placement pushes a table per pointer event. The new table here plays the same
            /// file second where the transport is and ends at warped second 1.4, so the group is the one there was:
            /// the table is swapped in place, the stretcher carries on without a restart (its idle instance is never
            /// touched), and the take falls silent where the new table ends, 2 s in at 70 %, which the old one would
            /// not.
            @Test("a table change that keeps the grouping does not restart and the group reads the new table")
            func tableChangeKeepingTheGroupingSwapsInPlace() async throws {
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
                // 1.5 s at 70 % is warped second 1.05.
                let before = try rig.render(seconds: 1.5)
                rig.backend.setPlaybackAlignment(warp: nil, segments: [], trackSegments: [
                    "take": [RecordingSegment(sourceStart: 0, sourceEnd: 1.4, outputStart: 0)],
                ])
                let after = try rig.render(seconds: 0.6)

                try #require(recorder.made.count == 2, "the group keeps its pair")
                #expect(recorder.made[0].calls.isEmpty, "the idle instance was never restarted")
                // Warped second 1.4, where the new table ends, is 0.5 s after the change.
                let playing = Array(before.suffix(100)) + after[..<Fixtures.frame(0.45)]
                let largestStep = zip(playing.dropFirst(), playing).map { abs($0 - $1) }.max() ?? 1
                #expect(largestStep < 0.01, "largest step between frames: \(largestStep)")
                let near = after[Fixtures.frame(0.45)]
                #expect(abs(near - 0.5) < 0.01, "just before the new table's end: \(near)")
                let tail = after[Fixtures.frame(0.55)...].map(abs).max() ?? 1
                #expect(tail < 1e-6, "past the new table's end the take peaks at \(tail)")
            }

            /// Stems A and B share one table, so one group. B's new table plays the same second where the transport
            /// is, but it is another table, so the group splits: the group A keeps restarts on A alone, primed on the
            /// idle instance of its pair, and B starts on a new pair, both crossfaded, so A + B never dips or doubles.
            @Test("a table change that splits a shared group restarts the affected groups")
            func tableChangeSplittingAGroupRestartsIt() async throws {
                let recorder = FakeStretcherRecorder()
                let rig = try await Self.rig(recorder.factory)
                defer { rig.finish() }
                rig.backend.setRate(0.7)
                let stems = try Self.stems(a: 0, b: 0)
                rig.backend.setRecordingTracks(stems.tracks)
                rig.backend.setPlaybackAlignment(warp: nil, segments: [], trackSegments: [
                    "a": Fixtures.wholeRecording(4), "b": Fixtures.wholeRecording(4),
                ])
                rig.backend.play()
                let before = try rig.render(seconds: 0.5)
                try #require(recorder.made.count == 2, "one pair for the one table")
                #expect(recorder.made[0].calls.isEmpty, "the first stream plays on the second instance")
                rig.backend.setPlaybackAlignment(warp: nil, segments: [], trackSegments: [
                    "a": Fixtures.wholeRecording(4), "b": Fixtures.wholeRecording(3),
                ])
                let after = try rig.render(seconds: 0.3)

                try #require(recorder.made.count == 4, "B's new group gets a pair")
                let seek = Call.seek(frames: recorder.made[0].seekLength(rate: Self.rate70), rate: Self.rate70)
                #expect(recorder.made[0].calls.prefix(3) == [.reset, .transpose(0), seek], "A's group restarted")
                #expect(recorder.made[2].seeks.isEmpty, "B's group starts on the second instance of its new pair")
                #expect(recorder.made[3].seeks.count == 1, "B's group started once")
                let level = Self.range(Array(before[Self.fadeFrames...]) + after)
                #expect(level.lowest > 0.395 && level.highest < 0.405, "A + B across the split: \(level)")
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

            /// Stem A plays the shared table and stem B a table of its own, so they are two groups, and B's new table
            /// keeps them so: it plays the same second where the transport is and ends at warped second 0.6, 0.857 s in
            /// at 70 %. Neither group restarts — the idle instance of each pair is never touched — and B, reading its
            /// new table, falls silent where it ends while A plays on.
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
                rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4), trackSegments: [
                    "b": [RecordingSegment(sourceStart: 0, sourceEnd: 0.6, outputStart: 0)],
                ])
                let after = try rig.render(seconds: 0.5)

                #expect(recorder.made.count == 4, "no new pair")
                #expect(recorder.made[0].calls.isEmpty, "A's group, on the shared table, was not restarted")
                #expect(recorder.made[2].calls.isEmpty, "B's group kept its grouping, so it was not restarted either")
                let both = Self.range(Array(before[Self.fadeFrames...]) + after[..<Fixtures.frame(0.3)])
                #expect(both.lowest > 0.395 && both.highest < 0.405, "A + B across the change: \(both)")
                // B's new table ends 0.357 s after the change.
                let alone = Self.range(Array(after[Fixtures.frame(0.45)...]))
                #expect(alone.lowest > 0.095 && alone.highest < 0.105, "A alone past B's new end: \(alone)")
            }
        }
    #endif
#endif
