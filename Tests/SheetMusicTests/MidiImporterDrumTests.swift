import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterDrumTests {
    @Test func drumTrackPopulatesHeadTypeForCrossNotehead() {
        // Pitch 42 = closed hi-hat → "cross" notehead.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 42, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 42, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480, isDrumTrack: true,
        )
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == "cross")
        } else {
            Issue.record("expected first chord")
        }
    }

    @Test func drumTrackPopulatesHeadTypeForBassDrum() {
        // Pitch 35 = acoustic bass drum → "normal" notehead.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 35, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 35, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480, isDrumTrack: true,
        )
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == "normal")
        } else {
            Issue.record("expected first chord")
        }
    }

    @Test func nonDrumTrackLeavesHeadTypeNil() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == nil)
        }
    }

    @Test func drumStaffSplitsHandsAndFeetIntoTwoVoices() throws {
        // Standard drum-pattern beat: kick (voice 2) + closed hi-hat
        // (voice 1) on beat 1, snare (voice 1) + kick (voice 2) on
        // beat 3. Voice 0 should carry hi-hat + snare; voice 1
        // should carry the two kicks.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            // Beat 1: kick + hi-hat together.
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 100)),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 42, velocity: 80)),
            TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 42, velocity: 0)),
            // Beat 3: snare + kick.
            TimedMidiEvent(tick: 960, event: .noteOn(channel: 9, pitch: 38, velocity: 100)),
            TimedMidiEvent(tick: 960, event: .noteOn(channel: 9, pitch: 36, velocity: 100)),
            TimedMidiEvent(tick: 1200, event: .noteOff(channel: 9, pitch: 38, velocity: 0)),
            TimedMidiEvent(tick: 1200, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)
        guard let drums = score.parts.firstIndex(where: { $0.instrument.useDrumset }) else {
            Issue.record("expected drumset part"); return
        }
        let measure = score.parts[drums].staves.first?.measures.first
        guard let measure else { Issue.record("expected measure"); return }
        #expect(measure.voices.count == 2)
        /// Walk every chord pitch in each voice — voice 0 should
        /// contain hi-hat (42) and snare (38); voice 1 should
        /// contain the two kicks (36).
        func pitches(in v: Voice) -> Set<Int> {
            var out: Set<Int> = []
            for el in v.elements {
                if case let .chord(c) = el {
                    for n in c.notes {
                        out.insert(n.pitch)
                    }
                }
            }
            return out
        }
        #expect(pitches(in: measure.voices[0]).contains(42))
        #expect(pitches(in: measure.voices[0]).contains(38))
        #expect(!pitches(in: measure.voices[0]).contains(36))
        #expect(pitches(in: measure.voices[1]) == [36])
    }

    @Test func drumStaffOmitsVoiceTwoWhenNoFootDrums() throws {
        // Pattern with only hi-hat + snare (no kick). Voice 1
        // should be omitted, leaving a single voice 0 with the hits.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 42, velocity: 80)),
            TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 42, velocity: 0)),
            TimedMidiEvent(tick: 960, event: .noteOn(channel: 9, pitch: 38, velocity: 100)),
            TimedMidiEvent(tick: 1200, event: .noteOff(channel: 9, pitch: 38, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)
        guard let drums = score.parts.firstIndex(where: { $0.instrument.useDrumset }) else {
            Issue.record("expected drumset part"); return
        }
        let measure = score.parts[drums].staves.first?.measures.first
        #expect(measure?.voices.count == 1)
    }

    @Test func drumPartGetsPercussionStaffDeclarationAndDrumLineMap() throws {
        // End-to-end: a drum-only track produces a Part with the
        // `group: "percussion"`, `defaultClefType: "PERC"` staff
        // declaration so the layout picks the percussion clef, plus
        // a fully populated `drumLineMap` so each GM pitch lands on
        // its conventional staff line.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 480, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 100)),
            TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 240, event: .noteOn(channel: 9, pitch: 38, velocity: 100)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 9, pitch: 38, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let drums = score.parts.first(where: { $0.instrument.useDrumset }) else {
            Issue.record("expected a drumset part"); return
        }
        // Staff declaration drives the layout's clef pick.
        let firstStaff = drums.staves.first
        #expect(firstStaff?.group == "percussion")
        #expect(firstStaff?.defaultClefType == "PERC")
        // drumLineMap covers the GM pitches used.
        #expect(drums.instrument.drumLineMap[36] != nil) // bass drum
        #expect(drums.instrument.drumLineMap[38] != nil) // snare
        #expect(drums.instrument.drumLineMap[42] != nil) // closed hi-hat
        #expect(drums.instrument.drumLineMap[49] != nil) // crash
        // Bass below snare (i.e. larger line index = lower).
        if let bass = drums.instrument.drumLineMap[36],
           let snare = drums.instrument.drumLineMap[38]
        {
            #expect(bass > snare)
        }
        // Crash above the staff (negative line index in our convention).
        if let crash = drums.instrument.drumLineMap[49] {
            #expect(crash < 0)
        }
    }

    // MARK: - Notes shorter than half a grid step

    /// One 4/4 bar at 480 PPQ: every note listed lasts `length` ticks. A second track holds a whole note on
    /// channel 0 so the bar is a full 1920 ticks whatever the hits are: the bar timeline is measured off the
    /// note-bearing tracks, and a drum slice carries no `endOfTrack` of its own.
    private static func oneBar(channel: Int, hits: [(tick: Int, pitch: Int)], length: Int) throws -> Score {
        let bed = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Bed"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 48, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 48, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        var events: [TimedMidiEvent] = [TimedMidiEvent(tick: 0, event: .meta(.trackName("Hits")))]
        for hit in hits {
            events.append(TimedMidiEvent(
                tick: hit.tick, event: .noteOn(channel: channel, pitch: hit.pitch, velocity: 100),
            ))
            events.append(TimedMidiEvent(
                tick: hit.tick + length, event: .noteOff(channel: channel, pitch: hit.pitch, velocity: 0),
            ))
        }
        events.sort { $0.tick < $1.tick }
        events.append(TimedMidiEvent(tick: 1920, event: .endOfTrack))
        let file = MidiFile(division: 480, format: 1, tracks: [bed, MidiTrack(events: events)])
        return try MidiImporter.parse(MidiWriter.write(file))
    }

    /// `(pitches, ticks)` of every chord in one voice; a rest is an empty pitch list.
    private static func shape(_ voice: Voice) -> [([Int], Int)] {
        voice.elements.compactMap { element in
            guard case let .chord(chord) = element else { return nil }
            return (chord.notes.map(\.pitch).sorted(), chord.duration.ticks(division: 480))
        }
    }

    /// A sequencer that writes every drum hit as a fixed 10-tick blip (1/48 of a beat) — common, since a drum
    /// note's length means nothing to a GM kit. Both ends of such a note snap to the same sixteenth, and dropping
    /// the zero-length result emptied the whole drum part: 171 bars of rests, nothing drawn, nothing played.
    ///
    /// MuseScore keeps every hit and, because a drum's duration is not musical, lengthens each one to the next hit
    /// in its voice, the end of its beat or the barline (`Simplify::minimizeNumberOfRests` → `lengthenNote`): an
    /// eighth-note hi-hat reads as eighths, and a kick on beats 1 and 3 as a quarter and a quarter rest each.
    @Test func blipLengthDrumHitsReadAsTheirRhythm() throws {
        let hats = (0 ..< 8).map { (tick: $0 * 240, pitch: 42) }
        let kicks = [(tick: 0, pitch: 36), (tick: 960, pitch: 36)]
        let score = try Self.oneBar(channel: 9, hits: hats + kicks, length: 10)
        guard let drums = score.parts.first(where: { $0.instrument.useDrumset }) else {
            Issue.record("expected a drumset part"); return
        }
        let voices = drums.staves[0].measures[0].voices
        #expect(voices.count == 2)
        let hands = Self.shape(voices[0])
        #expect(hands.map(\.0) == Array(repeating: [42], count: 8))
        #expect(hands.map(\.1) == Array(repeating: 240, count: 8))
        let feet = Self.shape(voices[1])
        #expect(feet.map(\.0) == [[36], [], [36], []])
        #expect(feet.map(\.1) == [480, 480, 480, 480])
    }

    /// The same blip on a pitched track is still a note that was played: it keeps one grid step (MuseScore's
    /// `findQuantizedNoteOffTime`: an off time that quantizes onto its on time moves one quantum later) rather than
    /// vanishing. A pitched note's length IS musical, so it is not stretched any further.
    @Test func blipLengthPitchedNotesKeepOneGridStep() throws {
        let score = try Self.oneBar(channel: 0, hits: (0 ..< 4).map { (tick: $0 * 480, pitch: 60) }, length: 10)
        guard let hits = score.parts.first(where: { $0.trackName == "Hits" }) else {
            Issue.record("expected the Hits part"); return
        }
        let shape = Self.shape(hits.staves[0].measures[0].voices[0])
        #expect(shape.map(\.1).reduce(0, +) == 1920)
        #expect(shape.filter { !$0.0.isEmpty }.count == 4)
        #expect(shape.filter { !$0.0.isEmpty }.allSatisfy { $0.1 == 120 })
    }
}
