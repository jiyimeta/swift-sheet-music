@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// A caesura's pause lasts its seconds at the tempo where it stands, and an arpeggio spreads at that tempo, on every
/// staff and in the cursor timeline alike (import-fidelity F2.9).
@Suite("Breath pauses and arpeggios at the map's tempo")
struct BreathPauseTempoTests {
    private static func chord(_ duration: NoteDuration, _ pitches: [Int], arpeggio: Bool = false) -> VoiceElement {
        .chord(Chord(
            duration: duration, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) }),
            arpeggio: arpeggio ? Arpeggio(subtype: 0) : nil,
        ))
    }

    /// Two staves, each: | C♩ caesura(1 s) D♩ E𝅗𝅥 | G𝅝 | at ♩ = 60 — or one arpeggiated chord a bar when `arpeggio`.
    private static func score(arpeggio: Bool = false) -> Score {
        let first: [VoiceElement] = arpeggio
            ? [Self.chord(.whole, [60, 64, 67, 72], arpeggio: true)]
            : [
                Self.chord(.quarter, [60]), .breath(Breath(kind: .caesura(.normal), pause: 1)),
                Self.chord(.quarter, [62]), Self.chord(.half, [64]),
            ]
        let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let measures = [
            Measure(voices: [Voice(elements: [meter] + first)]),
            Measure(voices: [Voice(elements: [Self.chord(.whole, [67])])]),
        ]
        let parts: [Part] = ["1", "2"].map { id in
            Part(id: id, instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])
        }
        let quarter60 = PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 1)))
        return Score(
            division: 480, parts: IdentifiedArray(parts),
            systemMeasures: [SystemMeasure(elements: [quarter60]), SystemMeasure()],
        )
    }

    private static func onsets(_ track: MidiTrack) -> [Int] {
        track.events.compactMap { event -> Int? in
            guard case let .noteOn(_, _, velocity) = event.event, velocity > 0 else { return nil }
            return event.tick
        }
    }

    @Test("the pause is one second at ♩ = 60 — 480 ticks — on every staff")
    func breathPauseUsesTheMapTempo() throws {
        let midi = try MidiRenderer.render(score: Self.score())
        try #require(midi.tracks.count == 2)
        for track in midi.tracks {
            #expect(Self.onsets(track) == [0, 960, 1440, 2400])
        }
    }

    @Test("the cursor timeline holds the same pause at the same tempo")
    func timelineAgrees() {
        let frames = PlaybackTimeline(score: Self.score()).frames
        let times = [0, 960, 1440, 2400].map { tick in frames.first { $0.tick == tick }?.timeSeconds }
        #expect(times == [0.0, 2.0, 3.0, 5.0])
    }

    @Test("an arpeggio spreads at the map's tempo on every staff")
    func arpeggioReadsTheMapTempo() throws {
        let midi = try MidiRenderer.render(score: Self.score(arpeggio: true))
        try #require(midi.tracks.count == 2)
        #expect(Self.onsets(midi.tracks[1]) == Self.onsets(midi.tracks[0]))
    }
}
