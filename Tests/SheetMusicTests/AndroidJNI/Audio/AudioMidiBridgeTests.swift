#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicMIDI
    import Testing

    // MARK: - Fixture helper

    private func loadFixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(
            forResource: "midi01",
            withExtension: "mscx",
        ))
        let bytes = try Data(contentsOf: url)
        return try ScoreBridge.loadScore(bytes: bytes)
    }

    /// One part, tick-0 piano (program 0, no declared channel — takes 0),
    /// mid-score `<InstrumentChange>` to accordion (program 21, declares
    /// `<midiChannel>5</midiChannel>`). Piano and accordion have
    /// different `InstrumentChannel` values, so `LiveChannelPlan.build`
    /// does NOT collapse them — it draws two distinct live channels via
    /// `takeLiveChannel()`, giving a remap that is provably not the
    /// identity map (see `renderMidiChannelsFollowLiveChannelPlan`).
    private func loadInstrumentChangeFixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(
            forResource: "instrument-change",
            withExtension: "mscx",
        ))
        let bytes = try Data(contentsOf: url)
        return try ScoreBridge.loadScore(bytes: bytes)
    }

    // MARK: - T14/Task 10: MidiChannelRemap (plan-driven) + renderMidi
    //
    // `AudioMidiBridge.relabelChannelsToTrackIndex` — which force-rewrote
    // every channel to `trackIdx & 0x0F` — is deleted (Task 10). Channel
    // assignment on Android is now driven by `LiveChannelPlan` /
    // `MidiChannelRemap`, the same plan-driven mapping the SMF export path
    // never touches. These tests exercise `MidiChannelRemap.apply`
    // directly (it lives in `SheetMusicMIDI`) with the same event-type and
    // field-preservation coverage the deleted helper's tests had.

    struct AudioMidiBridgeRenderMidiTests {
        @Test func remapAppliesPlanPerSourceChannel() {
            // Two tracks, each on a different source channel at port 0 —
            // the live plan maps each independently, unlike the deleted
            // helper's trackIdx-keyed scheme.
            var midi = MidiFile(division: 480, tracks: [
                MidiTrack(events: [
                    TimedMidiEvent(
                        tick: 0,
                        event: .noteOn(channel: 0, pitch: 60, velocity: 96),
                    ),
                ]),
                MidiTrack(events: [
                    TimedMidiEvent(
                        tick: 0,
                        event: .noteOn(channel: 1, pitch: 62, velocity: 96),
                    ),
                ]),
            ])
            let plan = LiveChannelPlan(
                strips: [],
                remap: [
                    MidiChannelKey(port: 0, channel: 0): 0,
                    MidiChannelKey(port: 0, channel: 1): 5,
                ],
                ordinalByTimelineIndex: [],
            )
            MidiChannelRemap.apply(midi: &midi, plan: plan)
            if case let .noteOn(ch, _, _) = midi.tracks[0].events[0].event {
                #expect(ch == 0)
            } else {
                Issue.record("Expected noteOn in track 0")
            }
            if case let .noteOn(ch, _, _) = midi.tracks[1].events[0].event {
                #expect(ch == 5)
            } else {
                Issue.record("Expected noteOn in track 1")
            }
        }

        @Test func remapChannelBearingEvents() {
            var midi = MidiFile(division: 480, tracks: [
                MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .noteOn(channel: 5, pitch: 60, velocity: 80)),
                    TimedMidiEvent(tick: 1, event: .noteOff(channel: 5, pitch: 60, velocity: 0)),
                    TimedMidiEvent(tick: 2, event: .controlChange(channel: 5, controller: 7, value: 100)),
                    TimedMidiEvent(tick: 3, event: .programChange(channel: 5, program: 40)),
                    TimedMidiEvent(tick: 4, event: .pitchBend(channel: 5, value: 8192)),
                    // Meta/endOfTrack should not be touched
                    TimedMidiEvent(tick: 5, event: .endOfTrack),
                ]),
            ])
            let plan = LiveChannelPlan(
                strips: [],
                remap: [MidiChannelKey(port: 0, channel: 5): 0],
                ordinalByTimelineIndex: [],
            )
            MidiChannelRemap.apply(midi: &midi, plan: plan)
            let events = midi.tracks[0].events
            if case let .noteOn(ch, _, _) = events[0].event { #expect(ch == 0) }
            if case let .noteOff(ch, _, _) = events[1].event { #expect(ch == 0) }
            if case let .controlChange(ch, _, _) = events[2].event { #expect(ch == 0) }
            if case let .programChange(ch, _) = events[3].event { #expect(ch == 0) }
            if case let .pitchBend(ch, _) = events[4].event { #expect(ch == 0) }
            // endOfTrack unchanged
            #expect(events[5].event == .endOfTrack)
        }

        @Test func remapPreservesOtherFields() {
            var midi = MidiFile(division: 480, tracks: [
                MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 64, velocity: 72)),
                ]),
                MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .noteOff(channel: 0, pitch: 55, velocity: 10)),
                ]),
            ])
            let plan = LiveChannelPlan(
                strips: [],
                remap: [MidiChannelKey(port: 0, channel: 0): 3],
                ordinalByTimelineIndex: [],
            )
            MidiChannelRemap.apply(midi: &midi, plan: plan)
            if case let .noteOn(ch, pitch, velocity) = midi.tracks[0].events[0].event {
                #expect(ch == 3)
                #expect(pitch == 64)
                #expect(velocity == 72)
            }
            if case let .noteOff(ch, pitch, velocity) = midi.tracks[1].events[0].event {
                #expect(ch == 3)
                #expect(pitch == 55)
                #expect(velocity == 10)
            }
        }

        @Test func renderMidiProducesValidSMF() throws {
            let score = try loadFixtureScore()
            let data = try AudioMidiBridge.renderMidi(score: score)
            // SMF starts with "MThd"
            #expect(data.count > 14)
            #expect(data.prefix(4) == Data("MThd".utf8))
            // Re-parse to confirm structure
            let reparsed = try MidiReader.read(data)
            #expect(!reparsed.tracks.isEmpty)
            let totalEvents = reparsed.tracks.reduce(0) { $0 + $1.events.count }
            #expect(totalEvents > 0)
        }

        @Test func renderMidiChannelsFollowLiveChannelPlan() throws {
            // `midi01` alone can't prove the remap actually rewrites
            // anything: its single instrument's pre-remap channel and
            // its `takeLiveChannel()` draw land on the same number (0),
            // so a broken remap that left every channel untouched would
            // pass a membership check against it just as well as a
            // correct one. Use the instrument-change fixture instead,
            // where the accordion's declared channel (5) and its live
            // channel (1, verified below) differ — a genuine,
            // non-identity mapping the test can hold the implementation
            // to.
            let score = try loadInstrumentChangeFixtureScore()
            let plan = LiveChannelPlan.build(score: score)
            // Verified by construction (see fixture doc comment) and by
            // running this test: the plan draws live channel 0 for the
            // tick-0 piano and live channel 1 for the accordion — NOT 5,
            // the accordion's declared/rendered channel.
            #expect(Set(plan.strips.map(\.liveChannel)) == [0, 1])
            let data = try AudioMidiBridge.renderMidi(score: score)
            let midi = try MidiReader.read(data)
            var noteChannels: Set<Int> = []
            for track in midi.tracks {
                for event in track.events {
                    if case let .noteOn(ch, _, _) = event.event {
                        noteChannels.insert(ch)
                    }
                    if case .meta(.portChange) = event.event {
                        Issue.record("portChange meta should have been dropped")
                    }
                }
            }
            // Exact set equality — not membership — so a remap that
            // silently left channels untouched (identity) would be
            // caught: the untouched set would be {0, 5}, not {0, 1}.
            #expect(noteChannels == Set(plan.strips.map(\.liveChannel)))
            // The accordion's rendered/declared channel (5) must NOT
            // survive into the live SMF — its live channel is 1. This
            // is the assertion a channel-remap-turned-no-op would fail.
            #expect(!noteChannels.contains(5))
        }
    }

    // MARK: - T15: timelineSummary

    struct AudioMidiBridgeTimelineSummaryTests {
        @Test func timelineSummaryMatchesDirectTimeline() throws {
            let score = try loadFixtureScore()
            let summary = AudioMidiBridge.timelineSummary(score: score)
            let timeline = PlaybackTimeline(score: score)
            #expect(summary.totalTicks == Int64(timeline.totalTicks))
            #expect(
                summary.totalSecondsMicros
                    == Int64((timeline.totalSeconds * 1_000_000).rounded()),
            )
            #expect(summary.division == Int64(timeline.division))
        }

        @Test func timelineSummaryEquatable() throws {
            let score = try loadFixtureScore()
            let a = AudioMidiBridge.timelineSummary(score: score)
            let b = AudioMidiBridge.timelineSummary(score: score)
            #expect(a == b)
        }

        @Test func timelineSummaryPositiveValues() throws {
            let score = try loadFixtureScore()
            let summary = AudioMidiBridge.timelineSummary(score: score)
            #expect(summary.totalTicks > 0)
            #expect(summary.totalSecondsMicros > 0)
            #expect(summary.division > 0)
        }
    }

    // MARK: - T16: frameAtTick + frameForCursor

    struct AudioMidiBridgeFrameTests {
        @Test func frameAtTickFirstFrameRoundTrips() throws {
            let score = try loadFixtureScore()
            let timeline = PlaybackTimeline(score: score)
            guard let firstFrame = timeline.frames.first else {
                Issue.record("Expected at least one frame")
                return
            }
            let data = AudioMidiBridge.frameAtTick(
                score: score, tick: Int64(firstFrame.tick),
            )
            #expect(!data.isEmpty)
            let decoded = try FrameCodec.decode(data)
            #expect(decoded.tick == firstFrame.tick)
            #expect(decoded.cursor == firstFrame.cursor)
        }

        @Test func frameAtTickOutOfRangeReturnsEmpty() throws {
            let score = try loadFixtureScore()
            let data = AudioMidiBridge.frameAtTick(score: score, tick: -1)
            #expect(data.isEmpty)
        }

        @Test func frameForCursorFirstFrameRoundTrips() throws {
            let score = try loadFixtureScore()
            let timeline = PlaybackTimeline(score: score)
            guard let firstFrame = timeline.frames.first else {
                Issue.record("Expected at least one frame")
                return
            }
            let data = AudioMidiBridge.frameForCursor(
                score: score, cursor: firstFrame.cursor,
            )
            #expect(!data.isEmpty)
            let decoded = try FrameCodec.decode(data)
            #expect(decoded.tick == firstFrame.tick)
        }

        @Test func frameForCursorUnknownItemReturnsEmpty() throws {
            let score = try loadFixtureScore()
            let bogusAddr = StaffAddress(partIndex: 999, staffIndexInPart: 999)
            let bogusID = NoteID(
                staff: bogusAddr,
                measureIndex: 999,
                voiceIndex: 999,
                elementIndex: 999,
                noteIndexInChord: 999,
            )
            let data = AudioMidiBridge.frameForCursor(
                score: score, cursor: .item(.note(bogusID)),
            )
            #expect(data.isEmpty)
        }
    }

    // MARK: - T17: metronomeBeats + staffParams

    struct AudioMidiBridgeMetronomeStaffTests {
        @Test func metronomeBeatsRoundTrips() throws {
            let score = try loadFixtureScore()
            let data = AudioMidiBridge.metronomeBeats(score: score)
            #expect(!data.isEmpty)
            let decoded = try MetronomeBeatCodec.decodeArray(data)
            let direct = PlaybackTimeline.metronomeBeats(score: score)
            #expect(decoded.count == direct.count)
            for (d, b) in zip(decoded, direct) {
                #expect(d.tick == b.tick)
                #expect(d.isDownbeat == b.isDownbeat)
            }
        }

        @Test func staffParamsCountMatchesStaves() throws {
            let score = try loadFixtureScore()
            let data = AudioMidiBridge.staffParams(score: score)
            #expect(!data.isEmpty)
            let decoded = try StaffParamsCodec.decodeArray(data)
            #expect(decoded.count == score.totalStaffCount)
        }

        @Test func staffParamsFieldsMatchSource() throws {
            let score = try loadFixtureScore()
            let data = AudioMidiBridge.staffParams(score: score)
            let decoded = try StaffParamsCodec.decodeArray(data)
            for (idx, entry) in score.allStaves.enumerated() {
                let part = score.part(at: entry.address)
                let channel = part?.instrument.channels.first
                let expectedProgram = UInt8(clamping: channel?.program ?? 0)
                let expectedBank = UInt8(clamping: channel?.bank ?? 0)
                let expectedDrums = part?.instrument.useDrumset == true
                #expect(decoded[idx].staffIndex == idx)
                #expect(decoded[idx].program == expectedProgram)
                #expect(decoded[idx].bankLSB == expectedBank)
                #expect(decoded[idx].isDrums == expectedDrums)
            }
        }
    }

    // MARK: - T18: pitchAndStaffOfNote + earliestOf

    struct AudioMidiBridgePitchEarliestTests {
        @Test func pitchAndStaffOfNoteValidNote() throws {
            let score = try loadFixtureScore()
            // midi01.mscx voice 0 has: KeySig(0), TimeSig(1), Chord-60(2), Chord-61(3), ...
            // Use PlaybackTimeline.itemTicks to find the actual elementIndex
            let timeline = PlaybackTimeline(score: score)
            let noteIDsWithTicks: [(NoteID, Int)] = timeline.itemTicks.compactMap { id, tick in
                if case let .note(nid) = id { return (nid, tick) }
                return nil
            }
            guard let firstNote = noteIDsWithTicks.min(by: { $0.1 < $1.1 })?.0 else {
                Issue.record("No notes found in fixture timeline")
                return
            }
            let packed = AudioMidiBridge.pitchAndStaffOfNote(
                score: score, noteId: firstNote,
            )
            let pitch = Int((UInt64(bitPattern: packed) >> 32) & 0xFFFF_FFFF)
            let staffIdx = Int(UInt64(bitPattern: packed) & 0xFFFF_FFFF)
            // pitch 60 is the first note in midi01.mscx
            #expect(pitch == 60)
            #expect(staffIdx == 0)
        }

        @Test func pitchAndStaffOfNoteSentinelForInvalidNote() throws {
            let score = try loadFixtureScore()
            let bogusAddr = StaffAddress(partIndex: 999, staffIndexInPart: 0)
            let bogusId = NoteID(
                staff: bogusAddr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            )
            let packed = AudioMidiBridge.pitchAndStaffOfNote(score: score, noteId: bogusId)
            #expect(packed == Int64(bitPattern: 0xFFFF_FFFF_FFFF_FFFF))
        }

        @Test func earliestOfPicksLowerTick() throws {
            let score = try loadFixtureScore()
            let timeline = PlaybackTimeline(score: score)
            // Collect first two note IDs from itemTicks
            let noteItems = timeline.itemTicks.keys.filter {
                if case .note = $0 { return true }
                return false
            }
            guard noteItems.count >= 2 else {
                Issue.record("Need at least 2 note IDs for test")
                return
            }
            let sortedPairs = noteItems.compactMap { id -> (ScoreItemID, Int)? in
                guard let tick = timeline.itemTicks[id] else { return nil }
                return (id, tick)
            }.sorted { $0.1 < $1.1 }
            let ids = [sortedPairs[0].0, sortedPairs[1].0]
            let data = AudioMidiBridge.earliestOf(score: score, ids: ids)
            #expect(!data.isEmpty)
            let decoded = try ScoreItemIDCodec.decode(data)
            // earliest should be the one with the lowest tick
            let expectedEarliest = timeline.earliest(of: ids)
            #expect(decoded == expectedEarliest)
        }

        @Test func earliestOfEmptyListReturnsEmpty() throws {
            let score = try loadFixtureScore()
            let data = AudioMidiBridge.earliestOf(score: score, ids: [])
            #expect(data.isEmpty)
        }

        @Test func earliestOfUnresolvableIdsReturnsEmpty() throws {
            let score = try loadFixtureScore()
            let bogusAddr = StaffAddress(partIndex: 999, staffIndexInPart: 0)
            let bogusId = ScoreItemID.note(NoteID(
                staff: bogusAddr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            ))
            let data = AudioMidiBridge.earliestOf(score: score, ids: [bogusId])
            #expect(data.isEmpty)
        }
    }
#endif
