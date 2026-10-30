@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `ChordArticulation.Kind.shapesPlayback` is a copy of what the MIDI renderer decides (`velocityPreset(for:)` and
/// `gatePreset(for:)`, both private to SheetMusicMIDI, and the choke marker), so it is pinned here to the renderer's
/// own playback output: a kind changes the note events or the choke markers of a one-note bar exactly when the
/// predicate says it plays. The revoice split sends a mark that does not play only to the lowest part of a chord, so a
/// kind the renderer starts to shape must start answering `true`, or it would be dropped from the parts that sound it.
@Suite("ChordArticulation.Kind.shapesPlayback")
struct ChordArticulationPlaybackTests {
    private static let kinds: [ChordArticulation.Kind] = ChordArticulation.Kind.modeled + [.unknown(subtype: "x")]

    /// Every note-on, note-off and choke marker of a one-note bar, with its tick, the kind's articulation on the chord
    /// or not.
    ///
    /// The note is a crash, so a choke has a cymbal to stop. The instrument plays a plain note at a 90% gate. A
    /// tenuto's preset is 100%, which only shows against a plain gate under 100%; the fixture's drumset names no
    /// preset, so its plain notes are 100% and would hide it.
    private static func playedEvents(carrying kind: ChordArticulation.Kind?) throws -> [String] {
        var score = RevoiceFixtures.editingChord(
            RevoiceFixtures.score([["C/4 r/4 r/2"]]), measure: 0, voice: 0, element: 1,
        ) { chord in
            if let kind { chord.articulations = [ChordArticulation(kind: kind)] }
        }
        score.parts.updateValue(at: 0) { $0.instrument.articulations = [InstrumentArticulation(gateTime: 90)] }
        return try MidiRenderer.renderForPlayback(score: score).tracks.flatMap { track in
            track.events.compactMap { timed -> String? in
                switch timed.event {
                case .noteOn, .noteOff: "tick \(timed.tick): \(timed.event)"
                case let .controlChange(_, controller, _) where controller == ChokeMarker.controller:
                    "tick \(timed.tick): \(timed.event)"
                default: nil
                }
            }
        }
    }

    @Test func `the predicate agrees with the renderer for every kind`() throws {
        let plain = try Self.playedEvents(carrying: nil)
        #expect(!plain.isEmpty)
        for kind in Self.kinds {
            let heard = try Self.playedEvents(carrying: kind) != plain
            #expect(heard == kind.shapesPlayback, "\(kind): the renderer \(heard ? "shapes" : "does not shape") it")
        }
    }
}
