import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct MidiRendererTests {
    @Test func rendersMidi01HeaderAndNotes() throws {
        let url = try #require(TestResources.url(forResource: "midi01", withExtension: "mscx"))
        let score = try MSCXParser.parse(Data(contentsOf: url))
        let file = try MidiRenderer.render(score: score)

        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)

        let track = file.tracks[0]

        let tickZeroEvents = track.events.filter { $0.tick == 0 }.map(\.event)
        #expect(tickZeroEvents.contains(.meta(.trackName("Voice"))))
        let expectedTimeSig = MetaEvent.timeSignature(
            numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
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
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return (ev.tick, pitch) } else { return nil }
        }
        #expect(noteOns.count == 4)
        #expect(noteOns.map(\.0) == [0, 480, 960, 1440])
        #expect(noteOns.map(\.1) == [60, 61, 62, 63])

        // Four note-off events at on-tick + 479 (mirrors midi01-ref.mid).
        let noteOffs: [(Int, Int)] = track.events.compactMap { ev in
            if case let .noteOff(_, pitch, _) = ev.event { return (ev.tick, pitch) }
            if case let .noteOn(_, pitch, vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
        #expect(noteOffs.count == 4)
        #expect(noteOffs.map(\.0) == [479, 959, 1439, 1919])

        // EndOfTrack is last.
        #expect(track.events.last?.event == .endOfTrack)
    }

    /// MuseScore writes all tempo into the first track (`exportmidi.cpp:55`, `:186-199`), whichever staff the
    /// `<Tempo>` belongs to: a tempo whose `originalStaff` is the second staff still lands on track 0, once.
    @Test func tempoOfTheSecondStaffIsWrittenOnTrackZeroOnly() throws {
        let bar = Measure(voices: [Voice(elements: Array(repeating: VoiceElement.rest(duration: .quarter), count: 4))])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano"),
            staves: [Staff(measures: [bar]), Staff(measures: [bar])],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: [PositionedSystemElement(
                position: MeasurePosition(numerator: 1, denominator: 4),
                element: .tempo(Tempo(beatsPerSecond: 3)),
                originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            )])],
        )
        let file = try MidiRenderer.render(score: score)
        #expect(file.tracks.count == 2)
        func tempos(_ track: MidiTrack) -> [(tick: Int, micros: Int)] {
            track.events.compactMap { timed in
                guard case let .meta(.tempo(micros)) = timed.event else { return nil }
                return (timed.tick, micros)
            }
        }
        // Track 0: the 120 BPM header at tick 0, then 180 BPM (3 bps; 60_000_000 / 180 = 333_333) at the quarter.
        let first = tempos(file.tracks[0])
        #expect(first.map(\.tick) == [0, 480])
        #expect(first.map(\.micros) == [500_000, 333_333])
        #expect(tempos(file.tracks[1]).isEmpty)
    }
}
