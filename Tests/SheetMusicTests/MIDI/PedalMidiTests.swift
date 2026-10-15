import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Pedal playback follows MuseScore 4: a pedal sounds unless `<play>0</play>`
/// (`Spanner::playSpanner`, `engraving/playback/metaparsers/internal/spannersmetaparser.cpp:62-64`, which checks the
/// play flag and never visibility), as CC64 = 127 at its start and 0 at its end
/// (`framework/audio/engine/internal/synthesizers/fluidsynth/fluidsequencer.cpp:197-210`). Pedal playback is switched
/// off in the public `render(score:)` until every engine releases the damper on stop; these tests run the pedal-on
/// path.
@Suite("Pedal in the rendered SMF")
struct PedalMidiTests {
    private static func cc64(_ file: MidiFile) -> [(tick: Int, value: Int, channel: Int)] {
        file.tracks.flatMap(cc64(track:))
    }

    private static func cc64(track: MidiTrack) -> [(tick: Int, value: Int, channel: Int)] {
        track.events.compactMap { event in
            if case let .controlChange(channel, 64, value) = event.event { return (event.tick, value, channel) }
            return nil
        }
    }

    @Test("the public render sends no CC64 while pedal playback is switched off")
    func publicRenderSendsNoPedal() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("pedal-lines"))
        #expect(try !Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true)).isEmpty)
        #expect(try Self.cc64(MidiRenderer.render(score: score)).isEmpty)
        #expect(try Self.cc64(MidiRenderer.renderForPlayback(score: score)).isEmpty)
    }

    @Test("a pedal over bars 1-2 sends 127 at its start and 0 at its end, on the part's channel")
    func simplePedal() throws {
        let score = try LineVariantFixtures.score(pedal: "<Pedal/>", bars: 3, from: 0, over: 2)
        let sustain = try Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true))
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
        let sustain = try Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true))
        #expect(sustain.map(\.value) == [0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 1920])
    }

    @Test("<play>0</play> silences a pedal; a hidden pedal still sounds")
    func playFlagAndVisibility() throws {
        let muted = try LineVariantFixtures.score(pedal: "<Pedal><play>0</play></Pedal>", bars: 3, from: 0, over: 2)
        #expect(try Self.cc64(MidiRenderer.render(score: muted, includingSustainPedal: true)).isEmpty)
        let hidden = try LineVariantFixtures.score(
            pedal: "<Pedal><visible>0</visible></Pedal>", bars: 3, from: 0, over: 2,
        )
        #expect(try Self.cc64(MidiRenderer.render(score: hidden, includingSustainPedal: true)).count == 3)
    }

    @Test("two touching pedals release before they press")
    func touching() throws {
        let score = try LineVariantFixtures.score(pedals: [("<Pedal/>", 0, 1), ("<Pedal/>", 1, 1)], bars: 3)
        let sustain = try Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true))
        #expect(sustain.map(\.value) == [0, 127, 0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 1920, 1920, 3840])
    }

    /// The two staves of a part share its channel, and a sequencer merging two tracks keeps no order at one tick: were
    /// each staff's pedals in its own track, the lower staff's opening release at tick 0 could follow the upper
    /// staff's press there and silence bar 1's pedal.
    @Test("a grand staff's pedals go out in the part's first track, released before pressed at a shared tick")
    func grandStaffPedalsShareOneTrack() throws {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        let pedal = Spanner(
            kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 1),
        )
        let plain = Measure(voices: [Voice(elements: [.chord(chord)])])
        let pedalled = Measure(voices: [Voice(elements: [.spanner(pedal), .chord(chord)])])
        // The upper staff pedals bar 1, the lower staff bar 2.
        let upper = Staff(measures: [pedalled, plain, plain])
        let lower = Staff(measures: [plain, pedalled, plain])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [upper, lower])],
        )
        let file = try MidiRenderer.render(score: score, includingSustainPedal: true)
        try #require(file.tracks.count == 2)
        #expect(Self.cc64(track: file.tracks[1]).isEmpty)
        let sustain = Self.cc64(track: file.tracks[0])
        #expect(sustain.map(\.value) == [0, 127, 0, 127, 0])
        #expect(sustain.map(\.tick) == [0, 0, 1920, 1920, 3840])
    }

    /// A staff carrying its own meter has its own bar spans, and its notes play on them: its pedal must be projected
    /// through that staff's layout, not the first staff's, or it drifts off its notes from the first differing bar on.
    @Test("a lower staff in its own meter pedals on its own bars")
    func lowerStaffPedalFollowsItsOwnBars() throws {
        let whole = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        let dottedHalf = Chord(duration: .half.dotted(1), notes: ChordNotes([Note(pitch: 48, tpc: 14)]))
        let pedal = Spanner(
            kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 3, denominator: 4),
        )
        let fourFour = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let threeFour = VoiceElement.timeSignature(TimeSignature(numerator: 3, denominator: 4))
        let upper = Staff(measures: [
            Measure(voices: [Voice(elements: [fourFour, .chord(whole)])]),
            Measure(voices: [Voice(elements: [.chord(whole)])]),
            Measure(voices: [Voice(elements: [.chord(whole)])]),
        ])
        // The lower staff pedals its bar 2 (original ticks 1440..2880 in 3/4), which plays from 1920.
        let lower = Staff(measures: [
            Measure(voices: [Voice(elements: [threeFour, .chord(dottedHalf)])]),
            Measure(voices: [Voice(elements: [.spanner(pedal), .chord(dottedHalf)])]),
            Measure(voices: [Voice(elements: [.chord(dottedHalf)])]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [upper, lower])],
        )
        let file = try MidiRenderer.render(score: score, includingSustainPedal: true)
        try #require(file.tracks.count == 2)
        let lowerNoteOns = file.tracks[1].events.compactMap { event -> Int? in
            if case let .noteOn(_, 48, velocity) = event.event, velocity > 0 { return event.tick }
            return nil
        }
        let sustain = Self.cc64(track: file.tracks[0])
        #expect(sustain.map(\.value) == [0, 127, 0])
        // The press lands on the lower staff's own second note, wherever its bar plays.
        #expect(sustain.dropFirst().first?.tick == lowerNoteOns.dropFirst().first)
        #expect(sustain.map(\.tick) == [0, 1920, 3360])
    }

    @Test("a score without pedals renders no CC64")
    func noPedal() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("grace_after"))
        #expect(try Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true)).isEmpty)
    }

    @Test("the pedal fixture renders balanced presses and releases, plus one opening release per pedalled channel")
    func fixtureBalanced() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("pedal-lines"))
        let sustain = try Self.cc64(MidiRenderer.render(score: score, includingSustainPedal: true))
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
