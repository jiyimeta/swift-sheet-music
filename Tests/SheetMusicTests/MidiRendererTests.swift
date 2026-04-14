import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct MidiRendererTests {
    @Test func rendersMidi01HeaderAndNotes() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let score = try MSCXParser.parse(try Data(contentsOf: url))
        let file = try MidiRenderer.render(score: score)

        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)

        let track = file.tracks[0]

        let tickZeroEvents = track.events.filter { $0.tick == 0 }.map(\.event)
        #expect(tickZeroEvents.contains(.meta(.trackName("Voice"))))
        let expectedTimeSig = MetaEvent.timeSignature(
            numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
        )
        #expect(tickZeroEvents.contains(.meta(expectedTimeSig)))
        #expect(tickZeroEvents.contains(.meta(.keySignature(sharpsFlats: 1, isMinor: false))))
        #expect(tickZeroEvents.contains(.meta(.tempo(microsecondsPerQuarter: 500_000))))
        #expect(tickZeroEvents.contains(.programChange(channel: 0, program: 52)))
        #expect(tickZeroEvents.contains(.controlChange(channel: 0, controller: 7, value: 100)))
        #expect(tickZeroEvents.contains(.controlChange(channel: 0, controller: 10, value: 64)))
        #expect(tickZeroEvents.contains(.meta(.portChange(port: 0))))

        // Four note-on events at quarter-note positions (pitches 60..63).
        let noteOns: [(Int, Int)] = track.events.compactMap { ev in
            if case .noteOn(_, let pitch, let vel) = ev.event, vel > 0 { return (ev.tick, pitch) } else { return nil }
        }
        #expect(noteOns.count == 4)
        #expect(noteOns.map(\.0) == [0, 480, 960, 1440])
        #expect(noteOns.map(\.1) == [60, 61, 62, 63])

        // Four note-off events at on-tick + 479 (mirrors midi01-ref.mid).
        let noteOffs: [(Int, Int)] = track.events.compactMap { ev in
            if case .noteOff(_, let pitch, _) = ev.event { return (ev.tick, pitch) }
            if case .noteOn(_, let pitch, let vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
        #expect(noteOffs.count == 4)
        #expect(noteOffs.map(\.0) == [479, 959, 1439, 1919])

        // EndOfTrack is last.
        #expect(track.events.last?.event == .endOfTrack)
    }
}
