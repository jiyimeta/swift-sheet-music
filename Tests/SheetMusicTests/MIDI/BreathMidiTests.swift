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

    @Test("breath mark with pause=0 does not shift the next chord")
    func breathMarkNoShift() throws {
        let s = try Self.score(breathKind: .breathMark(.comma), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        // Two notes one quarter apart at PPQ=480: onsets 0 and 480.
        #expect(noteOnTicks(in: midi) == [0, 480])
    }

    @Test("caesura with default pause shifts the next chord by pause-seconds")
    func caesuraDefaultPauseShifts() throws {
        // 120 BPM = 2 bps. Caesura .normal pause = 0.5s = 1 beat = 480 ticks at PPQ=480.
        let s = try Self.score(breathKind: .caesura(.normal), pause: nil)
        let midi = try MidiRenderer.render(score: s)
        // First chord onset = 0; second chord onset = 480 (quarter) + 480 (0.5s pause).
        #expect(noteOnTicks(in: midi) == [0, 960])
    }

    @Test("explicit pause overrides default")
    func explicitPauseOverridesDefault() throws {
        // 0.25s at 120 bpm / 480 ppq = 240 ticks.
        let s = try Self.score(breathKind: .breathMark(.comma), pause: 0.25)
        let midi = try MidiRenderer.render(score: s)
        #expect(noteOnTicks(in: midi) == [0, 720])
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
}
