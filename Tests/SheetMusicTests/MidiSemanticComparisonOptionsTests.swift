import Foundation
@testable import SheetMusicMIDI
import Testing

struct MidiSemanticComparisonOptionsTests {
    private func dataWith(events: [TimedMidiEvent]) throws -> Data {
        let lastTick = events.map(\.tick).max() ?? 0
        let track = MidiTrack(events: events + [TimedMidiEvent(tick: lastTick, event: .endOfTrack)])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        return try MidiWriter.write(file)
    }

    @Test func ignoreControlChangeDropsBothSides() throws {
        let withCC = try dataWith(events: [
            TimedMidiEvent(tick: 0, event: .controlChange(channel: 0, controller: 11, value: 80)),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
        ])
        let withoutCC = try dataWith(events: [
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
        ])
        // Without the option this would fail; with the option it passes.
        try MidiSemanticComparison.assertEquivalent(
            produced: withoutCC,
            reference: withCC,
            options: .init(ignoreControlChange: true),
        )
    }
}
