import Foundation
import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// The choke mark plays as a reserved control change at the end of the choked tie chain (`ChokeMarker`), on the
/// playback render only: a backend that understands it stops the cymbal there, every other synth ignores it, and an
/// exported SMF never carries it.
struct MidiRendererChokeTests {
    private struct Choke: Equatable {
        let tick: Int
        let channel: Int
        let key: Int
    }

    private static let choke = ChordArticulation(kind: .chokeCymbal)

    /// The drum fixture (`RevoiceFixtures`) with `marks` set on the chord at each `(measure, element)` of voice 0.
    /// Element 0 of bar 0 is the time signature.
    private static func drums(
        _ bars: [String], marking chords: [(measure: Int, element: Int)],
        _ marks: [ChordArticulation] = [choke],
    ) -> Score {
        var score = RevoiceFixtures.score(bars.map { [$0] })
        for spot in chords {
            score = RevoiceFixtures.editingChord(score, measure: spot.measure, voice: 0, element: spot.element) {
                $0.articulations = marks
            }
        }
        return score
    }

    /// One piano bar: `chord` on beat one, then rests.
    private static func piano(_ chord: Chord) -> Score {
        let measure = Measure(voices: [Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord), .rest(duration: .quarter), .rest(duration: .half),
        ])])
        return Score(
            division: 480,
            parts: [Part(id: "P1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [measure])])],
            systemMeasures: IdentifiedArray([SystemMeasure()]),
        )
    }

    private static func chokes(in file: MidiFile) -> [Choke] {
        file.tracks.flatMap(\.events).compactMap { timed in
            guard case let .controlChange(channel, controller, value) = timed.event,
                  controller == ChokeMarker.controller
            else { return nil }
            return Choke(tick: timed.tick, channel: channel, key: value)
        }
    }

    private static func noteOffs(of key: Int, in file: MidiFile) -> [Int] {
        file.tracks.flatMap(\.events).compactMap { timed in
            switch timed.event {
            case let .noteOff(_, pitch, _) where pitch == key: timed.tick
            case let .noteOn(_, pitch, 0) where pitch == key: timed.tick
            default: nil
            }
        }
    }

    @Test func `a choked crash quarter carries one choke at its note-off`() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.drums(["C/4 r/4 r/2"], marking: [(0, 1)]))
        let offs = Self.noteOffs(of: 49, in: file)
        #expect(offs.count == 1)
        #expect(Self.chokes(in: file) == offs.map { Choke(tick: $0, channel: MidiRenderer.drumChannel, key: 49) })
    }

    @Test func `an unmarked crash carries none`() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.drums(["C/4 r/4 r/2"], marking: []))
        #expect(Self.chokes(in: file).isEmpty)
    }

    /// The mark on the first note of a chain chokes at the end of the last: once, not at the first note's written end.
    @Test func `a crash tied across the barline chokes once, at the last note's off`() throws {
        let file = try MidiRenderer.renderForPlayback(
            score: Self.drums(["r/2 r/4 C/4~", "~C/4 r/4 r/2"], marking: [(0, 3)]),
        )
        let offs = Self.noteOffs(of: 49, in: file)
        #expect(offs.count == 1)
        #expect(offs.first.map { $0 > 4 * 480 } == true, "the chain ends in bar 2: \(offs)")
        #expect(Self.chokes(in: file).map(\.tick) == offs)
    }

    /// The mark on the last note of a chain chokes the whole chain too.
    @Test func `a mark on the tied-to note chokes the chain`() throws {
        let file = try MidiRenderer.renderForPlayback(
            score: Self.drums(["r/2 r/4 C/4~", "~C/4 r/4 r/2"], marking: [(1, 0)]),
        )
        #expect(Self.chokes(in: file).map(\.tick) == Self.noteOffs(of: 49, in: file))
    }

    @Test func `a staccato choke chokes at the staccato's shortened off`() throws {
        let file = try MidiRenderer.renderForPlayback(
            score: Self.drums(["C/4 r/4 r/2"], marking: [(0, 1)], [ChordArticulation(kind: .staccato), Self.choke]),
        )
        let offs = Self.noteOffs(of: 49, in: file)
        #expect(offs.first.map { $0 < 479 } == true, "the staccato shortens the note: \(offs)")
        #expect(Self.chokes(in: file).map(\.tick) == offs)
    }

    /// On a drum staff only the chord's cymbals are choked: the kick and the open hi-hat beside the crash ring on.
    @Test func `only the cymbal of a drum chord is choked`() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.drums(["C+K+46/4 r/4 r/2"], marking: [(0, 1)]))
        #expect(Self.chokes(in: file).map(\.key) == [49])
    }

    /// Every cymbal key of the set is choked.
    @Test(arguments: [49, 51, 52, 53, 55, 57, 59])
    func `each cymbal key is choked`(key: Int) throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.drums(["\(key)/4 r/4 r/2"], marking: [(0, 1)]))
        #expect(Self.chokes(in: file).map(\.key) == [key])
    }

    /// On a pitched staff every note of the chord is choked.
    @Test func `a piano chord chokes every note`() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15)],
            articulations: [Self.choke],
        )
        let file = try MidiRenderer.renderForPlayback(score: Self.piano(chord))
        let chokes = Self.chokes(in: file)
        #expect(chokes.map(\.key).sorted() == [60, 64, 67])
        #expect(chokes.allSatisfy { $0.channel != MidiRenderer.drumChannel })
        for choke in chokes {
            #expect(Self.noteOffs(of: choke.key, in: file) == [choke.tick])
        }
    }

    /// A roll chokes at the end of the roll: once, at the last stroke's off.
    @Test func `a choked crash roll chokes once, at the last stroke's off`() throws {
        let score = RevoiceFixtures.editingChord(
            Self.drums(["C/4 r/4 r/2"], marking: [(0, 1)]), measure: 0, voice: 0, element: 1,
        ) { $0.tremolo = Tremolo(subtype: .r16) }
        let file = try MidiRenderer.renderForPlayback(score: score)
        let offs = Self.noteOffs(of: 49, in: file)
        #expect(offs.count == 4)
        #expect(Self.chokes(in: file).map(\.tick) == [offs.max() ?? -1])
    }

    /// The SMF export renders without the marker: a file MuseScore or a DAW opens carries no undefined controller.
    @Test func `plain render and the SMF export carry no choke`() throws {
        let score = Self.drums(["C/4 C+K/4 r/2"], marking: [(0, 1), (0, 2)])
        #expect(try Self.chokes(in: MidiRenderer.render(score: score)).isEmpty)
        let marker: [UInt8] = [0xB9, UInt8(ChokeMarker.controller)]
        let exported = try [UInt8](SheetMusic.exportMIDI(score: score))
        #expect(!Self.contains(exported, marker))
        // The probe can see the marker: the playback render, written the same way, carries it.
        let played = try [UInt8](MidiWriter.write(MidiRenderer.renderForPlayback(score: score)))
        #expect(Self.contains(played, marker))
    }

    @Test func `the marker is CC 110, an undefined controller, and the cymbal set is the GM cymbals`() {
        #expect(ChokeMarker.controller == 110)
        #expect(ChokeMarker.cymbalKeys == [49, 51, 52, 53, 55, 57, 59])
    }

    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard bytes.count >= needle.count else { return false }
        return (0 ... bytes.count - needle.count).contains { Array(bytes[$0 ..< $0 + needle.count]) == needle }
    }
}
