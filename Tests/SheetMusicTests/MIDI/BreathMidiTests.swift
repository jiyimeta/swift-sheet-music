import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite("Breath MIDI playback")
struct BreathMidiTests {
    /// Build a minimal score via MSCX: 4/4, two quarter notes at
    /// 120 BPM, with a breath of the given kind between them.
    static func score(breathKind: Breath.Kind, pause: Double?) throws -> Score {
        let pauseLine = pause.map { "<pause>\($0)</pause>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Tempo><tempo>2</tempo></Tempo>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                  <Breath><subtype>\(breathKind.mscxSubtype)</subtype>\(pauseLine)</Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        return try MSCXParser.parse(Data(xml.utf8))
    }

    /// All note-on ticks in the rendered MIDI, sorted ascending.
    private func noteOnTicks(in midi: MidiFile) -> [Int] {
        var result: [Int] = []
        for track in midi.tracks {
            for ev in track.events {
                if case .noteOn = ev.event { result.append(ev.tick) }
            }
        }
        return result.sorted()
    }

    /// All note-off ticks in the rendered MIDI, sorted ascending.
    private func noteOffTicks(in midi: MidiFile) -> [Int] {
        var result: [Int] = []
        for track in midi.tracks {
            for ev in track.events {
                if case .noteOff = ev.event { result.append(ev.tick) }
            }
        }
        return result.sorted()
    }

    /// All tempo meta events in the rendered MIDI as
    /// `(tick, microsecondsPerQuarter)` pairs, sorted by tick.
    private func tempoMetaEvents(in midi: MidiFile) -> [(tick: Int, micros: Int)] {
        var out: [(tick: Int, micros: Int)] = []
        for track in midi.tracks {
            for ev in track.events {
                if case let .meta(meta) = ev.event,
                   case let .tempo(micros) = meta
                {
                    out.append((tick: ev.tick, micros: micros))
                }
            }
        }
        return out.sorted { $0.tick < $1.tick }
    }

    @Test("breath mark with pause=0 does not shift the next chord")
    func breathMarkNoShift() throws {
        let s = try Self.score(breathKind: .breathMark(.comma), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        // Two notes one quarter apart at PPQ=480: onsets 0 and 480.
        #expect(noteOnTicks(in: midi) == [0, 480])
    }

    @Test("caesura with default pause realizes pause-seconds via tempo bookend")
    func caesuraDefaultPauseShifts() throws {
        // 120 BPM = 2 bps. Caesura .normal pause = 0.5s. With tempo
        // bookends (vs. tick shifting), the next chord stays at tick
        // 480 (right after the first quarter); a slow-tempo meta
        // event at tick 480 consumes the 0.5s of wall clock.
        // Slow micros = 0.5 * 1_000_000 * 480 = 240_000_000.
        // Restore at tick 481 = 1_000_000 / 2.0 = 500_000.
        let s = try Self.score(breathKind: .caesura(.normal), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        #expect(noteOnTicks(in: midi) == [0, 480])
        let tempos = tempoMetaEvents(in: midi)
        #expect(
            tempos.contains { $0.tick == 480 && $0.micros == 240_000_000 },
            "expected slow-tempo bookend at tick 480; got \(tempos)",
        )
        #expect(
            tempos.contains { $0.tick == 481 && $0.micros == 500_000 },
            "expected restore-tempo bookend at tick 481; got \(tempos)",
        )
    }

    @Test("explicit pause overrides default")
    func explicitPauseOverridesDefault() throws {
        // breathMark with explicit pause = 0.25s at 120 BPM / 480 PPQ.
        // Next chord stays at tick 480; slow micros = 0.25 *
        // 1_000_000 * 480 = 120_000_000.
        let s = try Self.score(breathKind: .breathMark(.comma), pause: 0.25)
        let midi = try MidiRenderer.render(score: s)
        #expect(noteOnTicks(in: midi) == [0, 480])
        let tempos = tempoMetaEvents(in: midi)
        #expect(
            tempos.contains { $0.tick == 480 && $0.micros == 120_000_000 },
            "expected slow-tempo bookend at tick 480; got \(tempos)",
        )
        #expect(
            tempos.contains { $0.tick == 481 && $0.micros == 500_000 },
            "expected restore-tempo bookend at tick 481; got \(tempos)",
        )
    }

    @Test("preceding chord's note-off stays at its natural release")
    func precedingChordNotShortened() throws {
        // Compare the caesura case against a zero-pause control: the
        // first note's release tick must not move when a caesura with
        // a non-zero pause follows. MuseScore inserts dead time after
        // the chord rather than shortening it.
        let withCaesura = try Self.score(breathKind: .caesura(.normal), pause: nil)
        let withoutPause = try Self.score(breathKind: .breathMark(.comma), pause: nil)
        let offsCaesura = try noteOffTicks(in: MidiRenderer.render(score: withCaesura))
        let offsControl = try noteOffTicks(in: MidiRenderer.render(score: withoutPause))
        #expect(offsCaesura.first == offsControl.first)
    }

    @Test("caesura restore tempo honours the in-effect tempo")
    func caesuraUsesTempoAtBreathTick() throws {
        // Score: 4/4, first chord at 120 BPM (2 bps), then a <Tempo>
        // change to 60 BPM (1 bps) just before the caesura, then the
        // caesura, then the second chord. With tempo bookends, the
        // next chord stays at tick 480. The restore-tempo event at
        // tick 481 should be the 60-BPM micros (1_000_000), NOT the
        // initial 120-BPM 500_000 — i.e. it samples the timeline at
        // tick 481 where the 60-BPM change is already in effect.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Tempo><tempo>2</tempo></Tempo>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                  <Tempo><tempo>1</tempo></Tempo>
                  <Breath><subtype>caesura</subtype></Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        let midi = try MidiRenderer.render(score: score)
        #expect(noteOnTicks(in: midi) == [0, 480])
        let tempos = tempoMetaEvents(in: midi)
        // Restore at tick 481 should reflect 60 BPM (1_000_000),
        // not the original 120 BPM (500_000).
        #expect(
            tempos.contains { $0.tick == 481 && $0.micros == 1_000_000 },
            "expected restore-tempo bookend at tick 481 = 60 BPM; got \(tempos)",
        )
    }
}
