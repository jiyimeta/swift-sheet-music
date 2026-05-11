import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Verifies that drumset/percussion parts (`<useDrumset>1</useDrumset>` in
/// mscx) are auto-routed to GM channel 10 (0-indexed 9) so DAWs like Logic
/// Pro pick up a drum-kit patch automatically. Mirrors MuseScore's
/// `MasterScore::reorderMidiMapping` in `dom/midimapping.cpp:300`.
struct DrumChannelTests {
    private static func makeChord(pitch: Int, tpc: Int = 14) -> Chord {
        Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)])
    }

    private static func makeStaff(chordPitch: Int) -> Staff {
        let voice = Voice(elements: [.chord(makeChord(pitch: chordPitch))])
        return Staff(measures: [Measure(voices: [voice])])
    }

    private static func makePart(
        useDrumset: Bool,
        channelOverride: Int? = nil,
        chordPitch: Int = 60,
    ) -> Part {
        let channel = InstrumentChannel(midiChannel: channelOverride)
        let instrument = Instrument(
            id: useDrumset ? "drum" : "test",
            articulations: [InstrumentArticulation()],
            channels: [channel],
            useDrumset: useDrumset,
        )
        let staff = makeStaff(chordPitch: useDrumset ? 38 : chordPitch)
        return Part(id: "P1", instrument: instrument, staves: [staff])
    }

    private static func channelOf(track: MidiTrack) -> Int? {
        for ev in track.events {
            switch ev.event {
            case let .noteOn(ch, _, _), let .noteOff(ch, _, _),
                 let .programChange(ch, _), let .controlChange(ch, _, _):
                return ch
            default: continue
            }
        }
        return nil
    }

    // MARK: - Tests

    @Test func drumOnlyScore_routesAllEventsToChannel9() throws {
        let part = Self.makePart(useDrumset: true)
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        // EVERY note-on/off and the program change must be on channel 9.
        for ev in track.events {
            switch ev.event {
            case let .noteOn(ch, _, vel) where vel > 0:
                #expect(ch == 9, "drum noteOn on channel \(ch) — expected 9")
            case let .noteOff(ch, _, _):
                #expect(ch == 9, "drum noteOff on channel \(ch) — expected 9")
            case let .programChange(ch, _):
                #expect(ch == 9, "program change on channel \(ch) — expected 9")
            default: continue
            }
        }
    }

    @Test func explicitMidiChannelOverridesDrumDefault() throws {
        // If the score author explicitly sets <midiChannel>5</midiChannel>
        // we honour it even when useDrumset is true.
        let part = Self.makePart(useDrumset: true, channelOverride: 5)
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)
        #expect(Self.channelOf(track: track) == 5)
    }

    @Test func mixedScore_drumOnNine_melodicNeverGetsNine() throws {
        // Three parts: melodic, drum, melodic. The drum part takes channel 9
        // without consuming a counter slot, so subsequent melodics keep
        // filling 0,1,2,... (matches MuseScore's getNextFreeMidiMapping).
        // The key invariant: NO melodic part is ever placed on channel 9.
        let drumPart = Self.makePart(useDrumset: true)
        let melodicStaff1 = Self.makeStaff(chordPitch: 60)
        let melodicStaff2 = Self.makeStaff(chordPitch: 64)
        let melodic1 = Part(
            id: "M1",
            instrument: Instrument(id: "melodic1", articulations: [InstrumentArticulation()]),
            staves: [melodicStaff1],
        )
        let melodic2 = Part(
            id: "M2",
            instrument: Instrument(id: "melodic2", articulations: [InstrumentArticulation()]),
            staves: [melodicStaff2],
        )
        let score = Score(division: 480, parts: [melodic1, drumPart, melodic2])
        let file = try MidiRenderer.render(score: score)
        #expect(file.tracks.count == 3)
        let channels = file.tracks.compactMap(Self.channelOf(track:))
        // melodic1 → 0, drum → 9, melodic2 → 1 (drum didn't consume a slot).
        #expect(channels == [0, 9, 1])
        // Strong invariant: every melodic part gets a non-9 channel.
        #expect(channels[0] != 9)
        #expect(channels[2] != 9)
    }

    @Test func melodicAfterDrumStillSkipsNineWhenAllocatorReachesIt() throws {
        // Eleven melodic parts followed by a drum part. The melodics fill
        // channels 0…10 (skipping 9) and the drum still lands on 9.
        var parts: [Part] = []
        for i in 0 ..< 11 {
            let staff = Self.makeStaff(chordPitch: 60 + i)
            parts.append(Part(
                id: "M\(i)",
                instrument: Instrument(id: "m\(i)", articulations: [InstrumentArticulation()]),
                staves: [staff],
            ))
        }
        let drumPart = Self.makePart(useDrumset: true)
        parts.append(drumPart)
        let score = Score(division: 480, parts: parts)
        let file = try MidiRenderer.render(score: score)
        let channels = file.tracks.compactMap(Self.channelOf(track:))
        // Melodic parts: 0,1,2,3,4,5,6,7,8,10,11 (skipping 9). Drum: 9.
        #expect(channels[0 ..< 11] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11])
        #expect(channels[11] == 9)
    }

    @Test func multipleDrumParts_allShareChannel9() throws {
        // Two drum parts both go to channel 9. GM percussion is keyed on note
        // number, not part — sharing the channel is the correct behaviour.
        let drum1 = Self.makePart(useDrumset: true)
        let drum2 = Self.makePart(useDrumset: true)
        let score = Score(division: 480, parts: [drum1, drum2])
        let file = try MidiRenderer.render(score: score)
        let channels = file.tracks.compactMap(Self.channelOf(track:))
        #expect(channels == [9, 9])
    }

    @Test func parseUseDrumsetFromMscx() throws {
        let xml = """
        <Instrument id="snare-drum">
          <useDrumset>1</useDrumset>
          <Channel>
            <program value="0"/>
          </Channel>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)
        #expect(instrument.useDrumset == true)
    }

    @Test func parseInstrumentWithoutUseDrumsetDefaultsFalse() throws {
        let xml = """
        <Instrument id="violin">
          <Channel>
            <program value="40"/>
          </Channel>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)
        #expect(instrument.useDrumset == false)
    }
}
