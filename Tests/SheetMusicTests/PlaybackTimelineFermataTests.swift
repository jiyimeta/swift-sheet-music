import Foundation
@testable import SheetMusicAudioCore
import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `PlaybackTimeline` is the notated tick→seconds clock every cursor / elapsed-time read goes
/// through, while the audio a host plays is `MidiRenderer.render(score:)`'s SMF. A fermata is
/// rendered as a pair of tempo bookends around its anchor chord, so the two clocks disagree by
/// the hold's extra time from the fermata onward unless the timeline folds the same bookends
/// into its own tempo map.
@Suite("PlaybackTimeline honors fermata holds")
struct PlaybackTimelineFermataTests {
    private static let division = 480

    /// Two 4/4 measures. Measure 0 is `[fermata, half C4, half D4]` — MusicXML's ordering, where
    /// the fermata precedes the chord it holds — and measure 1 is four quarters. A standard
    /// `fermataAbove` has `timeStretch` 1.5, so the held half note takes 1.5 s at 120 BPM rather
    /// than 1.0 s and every later onset is 0.5 s (one beat) later than the notated clock says.
    private static func fermataScore() -> Score {
        let half: (Int, Int) -> Chord = { pitch, tpc in
            Chord(duration: .half, notes: [Note(pitch: pitch, tpc: tpc)])
        }
        let quarter: (Int, Int) -> Chord = { pitch, tpc in
            Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)])
        }
        let m0 = Measure(voices: [Voice(elements: [
            .fermata(Fermata(subtype: "fermataAbove")),
            .chord(half(60, 14)),
            .chord(half(62, 16)),
        ])])
        let m1 = Measure(voices: [Voice(elements: [
            .chord(quarter(64, 18)),
            .chord(quarter(65, 13)),
            .chord(quarter(67, 15)),
            .chord(quarter(69, 17)),
        ])])
        return Score(
            division: division,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "i", articulations: [InstrumentArticulation()]),
                staves: [Staff(measures: [m0, m1])],
            )],
        )
    }

    /// Wall-clock seconds of `tick` in the rendered SMF, integrating every tempo meta in the
    /// file. Ties at one tick resolve to the LAST event in file order — the same rule a
    /// sequencer applies, and what makes a fermata's "open" bookend win over a same-tick score
    /// tempo.
    private static func midiSeconds(atTick tick: Int, in file: MidiFile) -> TimeInterval {
        var tempos: [(tick: Int, mpq: Int)] = []
        for track in file.tracks {
            for event in track.events {
                guard case let .meta(.tempo(mpq)) = event.event else { continue }
                if let last = tempos.last, last.tick == event.tick {
                    tempos.removeLast()
                }
                tempos.append((event.tick, mpq))
            }
        }
        tempos.sort { $0.tick < $1.tick }
        var seconds: TimeInterval = 0
        var lastTick = 0
        var mpq = 500_000
        for tempo in tempos where tempo.tick <= tick {
            seconds += TimeInterval(tempo.tick - lastTick) * TimeInterval(mpq)
                / TimeInterval(file.division) / 1_000_000
            lastTick = tempo.tick
            mpq = tempo.mpq
        }
        seconds += TimeInterval(tick - lastTick) * TimeInterval(mpq)
            / TimeInterval(file.division) / 1_000_000
        return seconds
    }

    @Test("the SMF really holds the fermata")
    func renderedMidiHoldsTheFermata() throws {
        let file = try MidiRenderer.render(score: Self.fermataScore())
        // Measure 1's downbeat: two half notes at 120 BPM = 2.0 s straight, 2.5 s with the hold.
        #expect(abs(Self.midiSeconds(atTick: 4 * Self.division, in: file) - 2.5) < 0.001)
    }

    @Test("timeline seconds match the rendered SMF past a fermata")
    func timelineMatchesMidiPastFermata() throws {
        let score = Self.fermataScore()
        let file = try MidiRenderer.render(score: score)
        let timeline = PlaybackTimeline(score: score)

        // Every frame the cursor can stop on must sit at the time its note actually sounds;
        // otherwise the playhead runs ahead of the audio for the rest of the piece.
        for frame in timeline.frames {
            let expected = Self.midiSeconds(atTick: frame.tick, in: file)
            #expect(
                abs(frame.timeSeconds - expected) < 0.001,
                "tick \(frame.tick): timeline \(frame.timeSeconds)s vs SMF \(expected)s",
            )
        }
    }

    @Test("total notated duration includes the hold")
    func totalSecondsIncludeTheHold() {
        let timeline = PlaybackTimeline(score: Self.fermataScore())
        // 8 quarters at 120 BPM = 4.0 s, plus 0.5 s of fermata hold.
        #expect(abs(timeline.totalSeconds - 4.5) < 0.001)
    }

    /// Two parts, a 60 BPM `<Tempo>` on the score, and the fermata written on the SECOND part's
    /// staff — the shape MuseScore produces, which replicates a system fermata onto every staff
    /// while writing the tempo marking once.
    private static func twoPartFermataOnLowerStaffScore() -> Score {
        let voice: (Bool) -> Voice = { withFermata in
            Voice(
                elements: (withFermata ? [.fermata(Fermata(subtype: "fermataAbove"))] : [])
                    + [
                        .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
                        .chord(Chord(duration: .half, notes: [Note(pitch: 62, tpc: 16)])),
                    ],
            )
        }
        let instrument = Instrument(id: "i", articulations: [InstrumentArticulation()])
        let staff: (Bool) -> Staff = { withFermata in
            Staff(measures: [
                Measure(voices: [voice(withFermata)]),
                Measure(voices: [voice(false)]),
            ])
        }
        return Score(
            division: division,
            parts: [
                Part(id: "P1", instrument: instrument, staves: [staff(false)]),
                Part(id: "P2", instrument: instrument, staves: [staff(true)]),
            ],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 1))),
            ])],
        )
    }

    /// Regression: the bookends used to be built per staff against that staff's FILTERED system
    /// elements, but `filterSystemElements` routes a system-level `<Tempo>` to the canonical
    /// staff alone. Staves 1…n therefore computed their hold against the 120 BPM default, and
    /// the close event they emitted — `500_000` µs/quarter — outranked the real tempo in the
    /// merged map, so the whole rest of the piece played at 120 BPM no matter what was written.
    @Test("a fermata on a lower staff does not reset the tempo to the 120 BPM default")
    func fermataOnLowerStaffKeepsTheScoreTempo() throws {
        let score = Self.twoPartFermataOnLowerStaffScore()
        let file = try MidiRenderer.render(score: score)
        var tempos: [(track: Int, tick: Int, mpq: Int)] = []
        for (index, track) in file.tracks.enumerated() {
            for event in track.events {
                guard case let .meta(.tempo(mpq)) = event.event else { continue }
                tempos.append((index, event.tick, mpq))
            }
        }
        // 60 BPM held by a standard fermata = 90 BPM's worth of µs/quarter, restored to 60 BPM
        // at the held half note's end. Nothing anywhere may restore 120 BPM (500_000).
        #expect(tempos.contains { $0.tick == 0 && $0.mpq == 1_000_000 })
        #expect(tempos.contains { $0.tick == 0 && $0.mpq == 1_500_000 })
        #expect(tempos.contains { $0.tick == 2 * Self.division && $0.mpq == 1_000_000 })
        #expect(!tempos.contains { $0.tick > 0 && $0.mpq == 500_000 })
        // And they are emitted once, on the first track, rather than duplicated per staff.
        #expect(tempos.allSatisfy { $0.track == 0 })
    }

    @Test("timeline matches the SMF when the fermata is on a lower staff")
    func timelineMatchesMidiForLowerStaffFermata() throws {
        let score = Self.twoPartFermataOnLowerStaffScore()
        let file = try MidiRenderer.render(score: score)
        let timeline = PlaybackTimeline(score: score)
        for frame in timeline.frames {
            let expected = Self.midiSeconds(atTick: frame.tick, in: file)
            #expect(
                abs(frame.timeSeconds - expected) < 0.001,
                "tick \(frame.tick): timeline \(frame.timeSeconds)s vs SMF \(expected)s",
            )
        }
    }
}
