import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// A tie chain is gated as a whole, as MuseScore gates it (`CompatMidiRender`'s `calculateTieLength` adds every link's
/// gated length), so how a held note is spelled does not move its release.
struct MidiRendererTieGateTests {
    static let division = 480
    static let pitch = 60

    static func release(of measures: [Measure], gate: Int) throws -> (on: Int, off: Int) {
        let staff = Staff(measures: measures)
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "flute", articulations: [InstrumentArticulation(name: nil, velocity: 100, gateTime: gate)],
            ),
            staves: [staff],
        )
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: part,
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: division,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        var ons: [Int] = []
        var offs: [Int] = []
        for event in events {
            switch event.event {
            case let .noteOn(_, pitch, velocity) where pitch == Self.pitch && velocity > 0: ons.append(event.tick)
            case let .noteOff(_, pitch, _) where pitch == Self.pitch: offs.append(event.tick)
            default: break
            }
        }
        try #require(ons.count == 1 && offs.count == 1, "one attack and one release: \(ons) \(offs)")
        return (ons[0], offs[0])
    }

    static func note(_ duration: NoteDuration, back: Bool = false, forward: Bool = false) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [
            Note(pitch: pitch, tpc: 14, tieForward: forward ? 1 : nil, tieBack: back ? 1 : nil),
        ]))
    }

    static func bar(_ elements: [VoiceElement]) -> Measure {
        Measure(voices: [Voice(elements: elements)])
    }

    @Test("a dotted half and a half tied to a quarter release at the same tick")
    func spellingDoesNotMoveTheRelease() throws {
        let dotted = try Self.release(of: [Self.bar([Self.note(.half.dotted(1)), .rest(duration: .quarter)])], gate: 95)
        let tied = try Self.release(of: [Self.bar([
            Self.note(.half, forward: true), Self.note(.quarter, back: true), .rest(duration: .quarter),
        ])], gate: 95)
        #expect(tied == dotted)
        // 95% of three beats, MuseScore's arithmetic: on + gated length − 1.
        #expect(dotted == (0, 1440 * 95 / 100 - 1))
    }

    @Test("a chain across a barline is gated as a whole, and the next note starts a fresh account")
    func chainAcrossABarline() throws {
        let measures = [
            Self.bar([.rest(duration: .half), Self.note(.half, forward: true)]),
            Self.bar([
                Self.note(.quarter, back: true, forward: true), Self.note(.quarter, back: true), .rest(duration: .half),
            ]),
        ]
        let chain = try Self.release(of: measures, gate: 90)
        // Four beats from beat 3 of bar 1, gated as one note: 90% of 1920.
        #expect(chain == (960, 960 + 1920 * 90 / 100 - 1))
    }

    @Test("at a full gate the chain sounds to its end, as before")
    func fullGateIsUnchanged() throws {
        let tied = try Self.release(of: [Self.bar([
            Self.note(.half, forward: true), Self.note(.half, back: true),
        ])], gate: 100)
        #expect(tied == (0, 1919))
    }
}
