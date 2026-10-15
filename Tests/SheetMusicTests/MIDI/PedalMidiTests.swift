import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Pedal playback follows MuseScore 4: a pedal sounds unless `<play>0</play>`
/// (`Spanner::playSpanner`, `engraving/playback/metaparsers/internal/spannersmetaparser.cpp:62-64`, which checks the
/// play flag and never visibility), as CC64 = 127 at its start and 0 at its end
/// (`framework/audio/engine/internal/synthesizers/fluidsynth/fluidsequencer.cpp:197-210`).
@Suite("Pedal in the rendered SMF")
struct PedalMidiTests {
    private static func cc64(_ file: MidiFile) -> [(tick: Int, value: Int, channel: Int)] {
        file.tracks.flatMap(\.events).compactMap { event in
            if case let .controlChange(channel, 64, value) = event.event { return (event.tick, value, channel) }
            return nil
        }
    }

    @Test("a pedal over bars 1-2 sends 127 at its start and 0 at its end, on the part's channel")
    func simplePedal() throws {
        let score = try LineVariantFixtures.score(pedal: "<Pedal/>", bars: 3, from: 0, over: 2)
        let sustain = try Self.cc64(MidiRenderer.render(score: score))
        #expect(sustain.map(\.value) == [0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 3840])
    }

    @Test("a pedal made in code, with no line properties at all, still sounds")
    func pedalMadeInCodeSounds() throws {
        // `lineProperties == nil` means "every property at its default", which includes playing back.
        let pedal = Spanner(
            kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 1),
        )
        #expect(pedal.lineProperties == nil)
        #expect(!pedal.isEndMarker)
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        let first = Measure(voices: [Voice(elements: [.spanner(pedal), .chord(chord)])])
        let second = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [first, second])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        let sustain = try Self.cc64(MidiRenderer.render(score: score))
        #expect(sustain.map(\.value) == [0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 1920])
    }

    @Test("<play>0</play> silences a pedal; a hidden pedal still sounds")
    func playFlagAndVisibility() throws {
        let muted = try LineVariantFixtures.score(pedal: "<Pedal><play>0</play></Pedal>", bars: 3, from: 0, over: 2)
        #expect(try Self.cc64(MidiRenderer.render(score: muted)).isEmpty)
        let hidden = try LineVariantFixtures.score(
            pedal: "<Pedal><visible>0</visible></Pedal>", bars: 3, from: 0, over: 2,
        )
        #expect(try Self.cc64(MidiRenderer.render(score: hidden)).count == 3)
    }

    @Test("two touching pedals release before they press")
    func touching() throws {
        let score = try LineVariantFixtures.score(pedals: [("<Pedal/>", 0, 1), ("<Pedal/>", 1, 1)], bars: 3)
        let sustain = try Self.cc64(MidiRenderer.render(score: score))
        #expect(sustain.map(\.value) == [0, 127, 0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 1920, 1920, 3840])
    }

    @Test("a score without pedals renders no CC64")
    func noPedal() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("grace_after"))
        #expect(try Self.cc64(MidiRenderer.render(score: score)).isEmpty)
    }

    @Test("the pedal fixture renders balanced presses and releases, plus one opening release per pedalled channel")
    func fixtureBalanced() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("pedal-lines"))
        let sustain = try Self.cc64(MidiRenderer.render(score: score))
        #expect(!sustain.isEmpty)
        let channels = Set(sustain.map(\.channel))
        #expect(sustain.filter { $0.value == 0 }.count == sustain.filter { $0.value == 127 }.count + channels.count)
        for channel in channels {
            let first = sustain.first { $0.channel == channel }
            #expect(first?.value == 0 && first?.tick == 0)
        }
        #expect(sustain.last?.value == 0)
    }
}
