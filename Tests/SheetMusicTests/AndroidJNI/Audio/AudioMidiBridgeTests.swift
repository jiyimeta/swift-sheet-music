#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
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
#endif
