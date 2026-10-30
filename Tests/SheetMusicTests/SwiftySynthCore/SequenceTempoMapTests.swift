#if canImport(SheetMusicAudioSwiftySynthCore)
    import Foundation
    import SheetMusicAudioSwiftySynthCore
    import SheetMusicMIDI
    import Testing

    /// Ticks to seconds and back on a loaded SMF's own tempo map — the clock the Android player speaks in ticks while
    /// SwiftySynth's sequencer keeps seconds.
    struct SequenceTempoMapTests {
        @Test func `with no tempo event a quarter lasts half a second`() {
            let map = SequenceTempoMap(division: 480, tempoChanges: [])
            #expect(abs(map.seconds(atTick: 480) - 0.5) < 1e-9)
            #expect(abs(map.tick(atSeconds: 1.5) - 1440) < 1e-9)
        }

        @Test func `a tempo change applies from its tick`() {
            let map = SequenceTempoMap(
                division: 480,
                tempoChanges: [
                    (tick: 0, microsecondsPerQuarter: 500_000), (tick: 960, microsecondsPerQuarter: 1_000_000),
                ],
            )
            #expect(abs(map.seconds(atTick: 960) - 1.0) < 1e-9)
            #expect(abs(map.seconds(atTick: 1440) - 2.0) < 1e-9)
            #expect(abs(map.tick(atSeconds: 2.0) - 1440) < 1e-9)
        }

        @Test(arguments: [0.0, 1, 479.5, 960, 961, 1440, 10000.25])
        func `ticks survive the round trip across a change and past the last event`(tick: Double) {
            let map = SequenceTempoMap(
                division: 480,
                tempoChanges: [
                    (tick: 0, microsecondsPerQuarter: 432_000), (tick: 960, microsecondsPerQuarter: 811_111),
                ],
            )
            #expect(abs(map.tick(atSeconds: map.seconds(atTick: tick)) - tick) < 1e-9)
        }

        @Test func `a time before the start is tick zero`() {
            let map = SequenceTempoMap(division: 480, tempoChanges: [])
            #expect(map.tick(atSeconds: -1) == 0)
            #expect(map.seconds(atTick: -10) == 0)
        }

        @Test func `read from an SMF, a tempo in any track counts`() throws {
            let tempo = MidiTrack(events: [
                TimedMidiEvent(tick: 960, event: .meta(.tempo(microsecondsPerQuarter: 1_000_000))),
                TimedMidiEvent(tick: 961, event: .endOfTrack),
            ])
            let notes = MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 100)),
                TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                TimedMidiEvent(tick: 1921, event: .endOfTrack),
            ])
            let smf = try MidiWriter.write(MidiFile(division: 480, format: 1, tracks: [notes, tempo]))
            let map = try #require(SequenceTempoMap(smf: smf))
            #expect(abs(map.seconds(atTick: 960) - 1.0) < 1e-9)
            #expect(abs(map.seconds(atTick: 1920) - 3.0) < 1e-9)
        }

        @Test func `bytes that are not an SMF read as nothing`() {
            #expect(SequenceTempoMap(smf: Data([1, 2, 3])) == nil)
        }
    }
#endif
