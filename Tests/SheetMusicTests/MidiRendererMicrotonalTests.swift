@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Verifies that a microtonal accidental SOUNDS: the note strikes its stored key and the channel's pitch wheel carries
/// the accidental's `centOffset` while it plays (`MicrotonalPitchWheel`).
///
/// C++: `CompatMidiRender`'s `playNote` (`engraving/compat/midi/compatmidirenderinternal.cpp`), which adds a constant
/// pitch-wheel function of `Accidental::subtype2centOffset` over the note's span.
@Suite("MIDI microtonal accidentals")
struct MidiRendererMicrotonalTests {
    private typealias Probe = GuitarBendMidiProbe

    private static func score(_ elements: [VoiceElement], useDrumset: Bool = false) -> Score {
        let instrument = Instrument(
            id: "test", articulations: [InstrumentArticulation()], useDrumset: useDrumset,
        )
        let staff = Staff(measures: [Measure(voices: [Voice(elements: elements)])])
        return Score(division: 480, parts: [Part(id: "P1", instrument: instrument, staves: [staff])])
    }

    private static func note(_ pitch: Int, tpc: Int = 14, _ accidental: Accidental? = nil) -> Note {
        Note(pitch: pitch, tpc: tpc, accidental: accidental)
    }

    private static func quarter(_ note: Note) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [note]))
    }

    private static func track(_ score: Score) throws -> MidiTrack {
        try #require(MidiRenderer.render(score: score).tracks.first)
    }

    /// Every pitch-bend and note-on, in stream order, so a test can read what the wheel says at each strike.
    private static func wheelAndStrikes(in track: MidiTrack) -> [String] {
        track.events.compactMap { event in
            switch event.event {
            case let .pitchBend(_, value): "\(event.tick) wheel \(value)"
            case let .noteOn(_, pitch, velocity) where velocity > 0: "\(event.tick) on \(pitch)"
            default: nil
            }
        }
    }

    @Test func `a score without a microtonal accidental emits no wheel at all`() throws {
        let track = try Self.track(Self.score([
            Self.quarter(Self.note(60, .sharp)), Self.quarter(Self.note(62, tpc: 16)),
        ]))
        #expect(Probe.bends(in: track).isEmpty)
    }

    @Test func `a quarter-tone flat strikes the natural key with the wheel a quarter tone down`() throws {
        // B♮ (71) under a Stein quarter-tone flat: MuseScore stores the natural letter and plays it 50 cents low.
        let track = try Self.track(Self.score([
            Self.quarter(Self.note(71, tpc: 19, .mirroredFlat)), .rest(duration: .quarter), .rest(duration: .quarter),
            Self.quarter(Self.note(72)),
        ]))
        let lowered = Probe.wheel(semitones: -0.5)
        // The base reaches the wheel BEFORE the key, so the attack is already in tune; the wheel goes back to
        // center half a beat after the release (479 + 240), clear of the note's release tail, and the plain C
        // after the rests finds it there.
        #expect(Self.wheelAndStrikes(in: track) == [
            "0 wheel \(lowered)", "0 on 71", "719 wheel \(MidiEvent.pitchBendCenter)", "1440 on 72",
        ])
        #expect(Probe.noteOffs(in: track).map(\.tick) == [479, 1919])
    }

    @Test func `the track's end recentres the wheel without lengthening the track`() throws {
        let track = try Self.track(Self.score([Self.quarter(Self.note(71, tpc: 19, .mirroredFlat))]))
        // The release reset would fall at 719; the track ends at 480 (one past the note-off), and the reset with it.
        #expect(Probe.bends(in: track).last.map { "\($0.tick) \($0.value)" } == "480 \(MidiEvent.pitchBendCenter)")
        #expect(track.events.last.map { "\($0.tick) \($0.event)" } == "480 endOfTrack")
    }

    @Test func `a three-quarter-tone flat lowers the natural letter by 150 cents`() throws {
        let track = try Self.track(Self.score([Self.quarter(Self.note(71, tpc: 19, .flatArrowDown))]))
        #expect(Probe.bends(in: track).first?.value == Probe.wheel(semitones: -1.5))
    }

    @Test func `a line keeps the wheel until a plain note takes it back`() throws {
        // Two quarter-flats then a plain C: the second strike needs no event (the wheel already says −50, and the
        // release reset between them is overtaken by its onset), and the plain note recentres it as it strikes.
        let track = try Self.track(Self.score([
            Self.quarter(Self.note(71, tpc: 19, .flatArrowUp)),
            Self.quarter(Self.note(71, tpc: 19, .flatArrowUp)),
            Self.quarter(Self.note(72)),
        ]))
        #expect(Self.wheelAndStrikes(in: track) == [
            "0 wheel \(Probe.wheel(semitones: -0.5))", "0 on 71", "480 on 71",
            "960 wheel \(MidiEvent.pitchBendCenter)", "960 on 72",
        ])
    }

    @Test func `a grace note sounds its own offset and hands the wheel back to its parent`() throws {
        let grace = GraceChord(
            graceType: .appoggiatura, duration: .eighth,
            notes: [Self.note(69, tpc: 17, .sharpSlash)], // A quarter-tone sharp
        )
        let parent = Chord(duration: .quarter, notes: [Self.note(71, tpc: 19)], graceNotesBefore: [grace])
        let strikes = try Self.wheelAndStrikes(in: Self.track(Self.score([.chord(parent)])))
        let graceOn = try #require(strikes.firstIndex { $0.hasSuffix("on 69") })
        let parentOn = try #require(strikes.firstIndex { $0.hasSuffix("on 71") })
        #expect(strikes[graceOn - 1].hasSuffix("wheel \(Probe.wheel(semitones: 0.5))"))
        #expect(strikes[parentOn - 1].hasSuffix("wheel \(MidiEvent.pitchBendCenter)"))
    }

    @Test func `every tremolo stroke sounds the note's offset`() throws {
        let chord = Chord(
            duration: .quarter, notes: [Self.note(71, tpc: 19, .koron)], tremolo: Tremolo(subtype: .r16),
        )
        let track = try Self.track(Self.score([.chord(chord)]))
        #expect(Probe.noteOns(in: track).count == 4)
        // One wheel event for the four strokes, and the reset after the last one releases.
        #expect(Probe.bends(in: track).map(\.value) == [
            Probe.wheel(semitones: -0.67), MidiEvent.pitchBendCenter,
        ])
    }

    @Test func `a portamento from a quarter-flat slides on top of the offset`() throws {
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 71, tpc: 19, accidental: .flatArrowUp, glissando: Glissando(style: .portamento))],
        )
        let track = try Self.track(Self.score([.chord(start), Self.quarter(Self.note(72))]))
        let lowered = Probe.wheel(semitones: -0.5) - MidiEvent.pitchBendCenter
        let slide = Probe.bends(in: track).filter { $0.tick < 480 }.map(\.value)
        // The slide's own peak (+1 semitone) lands a quarter tone lower than it would on a plain note.
        #expect(slide.max() == Probe.wheel(semitones: 1) + lowered)
        #expect(slide.min() == MidiEvent.pitchBendCenter + lowered)
        // The plain target strikes with the wheel centred.
        #expect(Self.wheelAndStrikes(in: track).suffix(2) == ["480 wheel \(MidiEvent.pitchBendCenter)", "480 on 72"])
    }

    @Test func `a bend onto a microtonal destination stops a quarter tone short`() throws {
        // C4 bent to a D quarter-tone flat: MuseScore's bend amount is 2 × 2 − 1 = 3 quarter tones.
        let start = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let end = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, accidental: .flatArrowUp, guitarBendBack: true)],
        )
        let track = try Self.track(Probe.makeScore(chords: [start, end]))
        #expect(Probe.bends(in: track).map(\.value).max() == Probe.wheel(semitones: 1.5))
    }

    @Test func `the drum channel is never retuned`() throws {
        let track = try Self.track(Self.score([Self.quarter(Self.note(38, .flatArrowUp))], useDrumset: true))
        #expect(Probe.bends(in: track).isEmpty)
    }

    @Test func `a rendered track carries no annotation`() throws {
        let track = try Self.track(Self.score([Self.quarter(Self.note(71, tpc: 19, .mirroredFlat))]))
        #expect(track.events.allSatisfy { $0.tuningCents == 0 })
    }
}
