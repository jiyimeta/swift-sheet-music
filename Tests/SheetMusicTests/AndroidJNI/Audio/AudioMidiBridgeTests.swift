#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicEditWire
    import SheetMusicMIDI
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

    // MARK: - T14: relabelChannelsToTrackIndex + renderMidi

    struct AudioMidiBridgeRenderMidiTests {
        @Test func relabelChannelsToTrackIndex() {
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
                        event: .noteOn(channel: 0, pitch: 62, velocity: 96),
                    ),
                ]),
            ])
            AudioMidiBridge.relabelChannelsToTrackIndex(&midi)
            // Track 0 events stay on channel 0
            if case let .noteOn(ch, _, _) = midi.tracks[0].events[0].event {
                #expect(ch == 0)
            } else {
                Issue.record("Expected noteOn in track 0")
            }
            // Track 1 events are relabeled to channel 1
            if case let .noteOn(ch, _, _) = midi.tracks[1].events[0].event {
                #expect(ch == 1)
            } else {
                Issue.record("Expected noteOn in track 1")
            }
        }

        @Test func relabelChannelBearingEvents() {
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
            AudioMidiBridge.relabelChannelsToTrackIndex(&midi)
            let events = midi.tracks[0].events
            if case let .noteOn(ch, _, _) = events[0].event { #expect(ch == 0) }
            if case let .noteOff(ch, _, _) = events[1].event { #expect(ch == 0) }
            if case let .controlChange(ch, _, _) = events[2].event { #expect(ch == 0) }
            if case let .programChange(ch, _) = events[3].event { #expect(ch == 0) }
            if case let .pitchBend(ch, _) = events[4].event { #expect(ch == 0) }
            // endOfTrack unchanged
            #expect(events[5].event == .endOfTrack)
        }

        @Test func relabelPreservesOtherFields() {
            var midi = MidiFile(division: 480, tracks: [
                MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 64, velocity: 72)),
                ]),
                MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .noteOff(channel: 0, pitch: 55, velocity: 10)),
                ]),
            ])
            AudioMidiBridge.relabelChannelsToTrackIndex(&midi)
            if case let .noteOn(_, pitch, velocity) = midi.tracks[0].events[0].event {
                #expect(pitch == 64)
                #expect(velocity == 72)
            }
            if case let .noteOff(_, pitch, velocity) = midi.tracks[1].events[0].event {
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

        @Test func renderMidiChannelsRelabeled() throws {
            let score = try loadFixtureScore()
            let data = try AudioMidiBridge.renderMidi(score: score)
            let midi = try MidiReader.read(data)
            // Each track's note-on events should have channel == trackIndex & 0x0F
            for (trackIdx, track) in midi.tracks.enumerated() {
                let expectedChannel = trackIdx & 0x0F
                for event in track.events {
                    if case let .noteOn(ch, _, _) = event.event {
                        #expect(ch == expectedChannel)
                    }
                }
            }
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
