import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// Real MusicXML scores routinely contain `<unpitched>` notes for percussion
/// staves (drum kits, etc.). The parser used to reject them with
/// `SheetMusicError.malformedScore`; this suite locks in support so the same
/// regression doesn't sneak back.
struct MusicXMLUnpitchedTests {
    @Test func parsesUnpitchedNote() throws {
        // Minimal partwise MusicXML: one part, one measure, one <unpitched>
        // note (display position A5 → MIDI 81). Mirrors the shape MuseScore
        // exports for a drum-kit staff.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <part-name>Drums</part-name>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <unpitched>
                  <display-step>A</display-step>
                  <display-octave>5</display-octave>
                </unpitched>
                <duration>4</duration>
                <type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try SheetMusic.loadScore(musicXMLData: Data(xml.utf8))
        #expect(score.parts.count == 1)
        #expect(score.totalStaffCount == 1)
        let voice = try #require(score.allStaves.first?.staff.measures.first?.voices.first)
        guard case let .chord(chord) = voice.elements.last else {
            Issue.record("expected a chord, got \(voice.elements)")
            return
        }
        // A5 = MIDI 81 (octave+1)*12 + 9.
        #expect(chord.notes.first?.pitch == 81)
    }

    /// Real percussion parts attach `<midi-instrument><midi-unpitched>` per
    /// drum sound. The note's `<instrument id>` selects which row to use,
    /// and the resulting MIDI pitch is `midi-unpitched − 1` (1-128 → 0-127).
    /// The part must also carry `useDrumset = true` so the renderer routes
    /// it to GM channel 10 (0-indexed: 9), which DAWs auto-treat as drums.
    @Test func unpitchedNoteResolvesToDrumPitch_andPartIsDrumset() throws {
        // <midi-unpitched>36</midi-unpitched> → MIDI 35 (Acoustic Bass Drum).
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <part-name>Drums</part-name>
              <score-instrument id="P1-I36">
                <instrument-name>Acoustic Bass Drum</instrument-name>
              </score-instrument>
              <midi-instrument id="P1-I36">
                <midi-channel>10</midi-channel>
                <midi-unpitched>36</midi-unpitched>
              </midi-instrument>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <unpitched>
                  <display-step>F</display-step>
                  <display-octave>4</display-octave>
                </unpitched>
                <duration>4</duration>
                <type>whole</type>
                <instrument id="P1-I36"/>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try SheetMusic.loadScore(musicXMLData: Data(xml.utf8))
        let part = try #require(score.parts.first)
        // Drum-set flag: the renderer's channel allocator uses this to put
        // the part on channel 9 (GM percussion).
        #expect(part.instrument.useDrumset == true)
        // Note pitch resolved via the drum table, NOT via display-step.
        let voice = try #require(score.allStaves.first?.staff.measures.first?.voices.first)
        guard case let .chord(chord) = voice.elements.last else {
            Issue.record("expected a chord, got \(voice.elements)"); return
        }
        #expect(chord.notes.first?.pitch == 35)

        // End-to-end: rendering produces note events on channel 9.
        let midiData = try SheetMusic.exportMIDI(score: score)
        let file = try MidiReader.read(midiData)
        let track = try #require(file.tracks.first)
        let drumOns = track.events.compactMap { ev -> (ch: Int, pitch: Int)? in
            if case let .noteOn(ch, pitch, vel) = ev.event, vel > 0 { return (ch, pitch) }
            return nil
        }
        #expect(drumOns.count == 1)
        #expect(drumOns.first?.ch == 9)
        #expect(drumOns.first?.pitch == 35)
    }

    /// Mid-channel detection: a part where `<midi-channel>10</midi-channel>`
    /// is present but no `<midi-unpitched>` mapping should still be flagged
    /// as a drumset (matches MuseScore's heuristic).
    @Test func midiChannel10AloneSetsDrumsetFlag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <midi-instrument id="P1-I1"><midi-channel>10</midi-channel></midi-instrument>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions></attributes>
              <note><pitch><step>C</step><octave>4</octave></pitch>
                    <duration>4</duration><type>whole</type></note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try SheetMusic.loadScore(musicXMLData: Data(xml.utf8))
        #expect(score.parts.first?.instrument.useDrumset == true)
    }

    /// Without `LocalizedError`, MusicXML parse errors used to surface in
    /// SwiftUI as opaque "SheetMusicError error 1" messages. The error must
    /// expose the case-specific reason via `errorDescription`.
    @Test(.enabled(if: isLocalizedErrorBridgingAvailable))
    func errorDescriptionShowsReason() throws {
        let badXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"/></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
              </attributes>
              <note><duration>4</duration></note>
            </measure>
          </part>
        </score-partwise>
        """
        do {
            _ = try SheetMusic.loadScore(musicXMLData: Data(badXML.utf8))
            Issue.record("expected parse failure")
        } catch let e as SheetMusicError {
            let description = e.localizedDescription
            #expect(
                description.contains("MusicXML"),
                "errorDescription should expose the reason, got: \(description)",
            )
        }
    }

    private static var isLocalizedErrorBridgingAvailable: Bool {
        #if SHEET_MUSIC_HAS_LOCALIZED_ERROR_DESCRIPTION_BRIDGING
            true
        #else
            false
        #endif
    }
}
