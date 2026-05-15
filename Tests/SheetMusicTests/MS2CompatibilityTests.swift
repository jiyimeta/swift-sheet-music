import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// MuseScore 2.x files use a few legacy spellings that our MS3/MS4-shaped
/// reader silently drops when handled naively. These tests pin the
/// compat behaviour for the three forms we hit on real MS2 inputs (e.g.
/// MuseScore 2.3.2-produced `.mscz`):
///
/// - `<duration z="N" n="D"/>` instead of `<duration>N/D</duration>`
///   on full-measure rests
/// - `<head>K</head>` where K is the `NoteHead::Group` enum integer
///   instead of MS3+'s string ("normal", "cross", …)
/// - flat-form `<Measure>` with all voices interleaved and
///   `<track>N</track>` tagging non-default voices, where MS3+ wraps
///   each voice in `<voice>…</voice>`.
struct MS2CompatibilityTests {
    @Test func measureRestReadsAttributeFormDuration() throws {
        // C++: MuseScore 2 `Fraction::write` emits `z` / `n` attrs on
        // `<duration>`. Under the `.measure` marker model the inner
        // `<duration>` is informational — encoders re-derive it from
        // the containing measure's effective duration — so the
        // decoder reads-and-discards either form. The regression this
        // test pins is that the parser doesn't choke on the MS2
        // attribute spelling. Resolution against a 5/4 bar still
        // recovers the right effective fraction.
        let xml = """
        <voice>
          <Rest>
            <durationType>measure</durationType>
            <duration z="5" n="4"/>
          </Rest>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        guard case let .chord(rest) = voice.elements.first, rest.notes.isEmpty else {
            Issue.record("expected one rest element, got \(voice.elements)")
            return
        }
        #expect(rest.duration == .measure)
        #expect(
            rest.duration
                .resolved(in: Fraction(numerator: 5, denominator: 4))
                .asFraction == Fraction(numerator: 5, denominator: 4),
        )
    }

    @Test func measureRestStillAcceptsSlashFormDuration() throws {
        let xml = """
        <voice>
          <Rest>
            <durationType>measure</durationType>
            <duration>5/4</duration>
          </Rest>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        guard case let .chord(rest) = voice.elements.first, rest.notes.isEmpty else {
            Issue.record("expected one rest element, got \(voice.elements)")
            return
        }
        #expect(rest.duration == .measure)
        #expect(
            rest.duration
                .resolved(in: Fraction(numerator: 5, denominator: 4))
                .asFraction == Fraction(numerator: 5, denominator: 4),
        )
    }

    @Test func numericNoteHeadMapsToStringName() throws {
        // C++: MuseScore 2 `libmscore/note.h` `NoteHead::Group` enum.
        // The renderer (`NoteheadRenderer`) keys off the MS3+ string
        // names, so unmapped integers silently fall back to "normal" —
        // dropping every cross / diamond head on percussion staves.
        let xml = """
        <voice>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>42</pitch><tpc>20</tpc><head>1</head></Note>
          </Chord>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>42</pitch><tpc>20</tpc><head>2</head></Note>
          </Chord>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>42</pitch><tpc>20</tpc><head>3</head></Note>
          </Chord>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>42</pitch><tpc>20</tpc><head>0</head></Note>
          </Chord>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        let heads = voice.elements.compactMap { element -> String? in
            guard case let .chord(c) = element, let n = c.notes.first else { return nil }
            return n.headType
        }
        #expect(heads == ["cross", "diamond", "triangle-up", "normal"])
    }

    @Test func ms3StringNoteHeadPassesThrough() throws {
        let xml = """
        <voice>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>42</pitch><tpc>20</tpc><head>cross</head></Note>
          </Chord>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        guard case let .chord(c) = voice.elements.first, let n = c.notes.first else {
            Issue.record("expected one chord with one note, got \(voice.elements)")
            return
        }
        #expect(n.headType == "cross")
    }

    @Test func flatMeasureSplitsVoicesByTrackTag() throws {
        // C++: MuseScore 2 `Measure::read` walks children sequentially,
        // resetting the score cursor on `<tick>` and dispatching by
        // `<track>` (= staff_index * 4 + voice_index). Without
        // demuxing, voice 1's chords get appended after voice 0 in a
        // single implicit voice, so they fire at the wrong tick and
        // some of voice 1 falls past the bar's end where the renderer
        // drops it.
        let xml = """
        <Measure number="1">
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
          </Chord>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>62</pitch><tpc>16</tpc></Note>
          </Chord>
          <tick>480</tick>
          <Chord>
            <track>21</track>
            <durationType>half</durationType>
            <Note><track>21</track><pitch>48</pitch><tpc>14</tpc></Note>
          </Chord>
        </Measure>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let measure = try Measure.decode(node)
        #expect(measure.voices.count == 2)
        #expect(measure.voices[0].elements.count == 2)
        #expect(measure.voices[1].elements.count == 1)
        guard case let .chord(v1) = measure.voices[1].elements[0],
              v1.notes.first?.pitch == 48
        else {
            Issue.record("voice 1 should hold the half-note pitch 48 chord")
            return
        }
    }

    @Test func ms2StaffTextSwingPromotedToSystem() throws {
        // C++: MuseScore 2 wrote swing inside <StaffText> even for a
        // score-wide directive (no UI distinction in 2.x). Without
        // promotion the renderer would route the swing only to the
        // originating staff, so drums / bass etc. stay straight while
        // the lead staff swings — the symptom that reported the bug.
        // MuseScore 3's MS2 import path promotes the tag to
        // <SystemText>; we mirror it.
        let xml = """
        <museScore version="2.06">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <StaffText>
                  <swing unit="eighth" ratio="60"/>
                  <text>Swing</text>
                </StaffText>
                <Rest>
                  <durationType>measure</durationType>
                  <duration z="4" n="4"/>
                </Rest>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        let swings = score.systemMeasures.flatMap { sm in
            sm.elements.compactMap { positioned -> Swing? in
                if case let .swing(s) = positioned.element { return s }
                return nil
            }
        }
        #expect(swings.count == 1)
        #expect(swings.first?.isSystemText == true)
        #expect(swings.first?.unit == .eighth)
        #expect(swings.first?.ratio == 60)
    }

    @Test func ms3StaffTextSwingRemainsStaffLocal() throws {
        // Mirror of the MS2 promotion test for a v3 file: a user who
        // explicitly authored a per-staff swing in MuseScore 3+
        // should keep that intent. Only the v2 path promotes.
        let xml = """
        <museScore version="3.02">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <StaffText>
                    <swing unit="eighth" ratio="60"/>
                    <text>Swing</text>
                  </StaffText>
                  <Rest>
                    <durationType>measure</durationType>
                    <duration>4/4</duration>
                  </Rest>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        let swings = score.systemMeasures.flatMap { sm in
            sm.elements.compactMap { positioned -> Swing? in
                if case let .swing(s) = positioned.element { return s }
                return nil
            }
        }
        #expect(swings.count == 1)
        #expect(swings.first?.isSystemText == false)
    }

    @Test func ms2TupletReferenceCloseImplicitly() throws {
        // MS2 marks every triplet member with <Tuplet>N</Tuplet>
        // referring to the preceding <Tuplet id="N"> declaration and
        // does not emit <endTuplet/>. Without injection, the stack
        // stays open and the following straight quarter is silently
        // scaled by 2/3 — collapsing the bar by a sixth and pushing
        // every later beat ahead.
        let xml = """
        <voice>
          <Tuplet id="1">
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Chord>
            <Tuplet>1</Tuplet>
            <durationType>eighth</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
          </Chord>
          <Chord>
            <Tuplet>1</Tuplet>
            <durationType>eighth</durationType>
            <Note><pitch>62</pitch><tpc>16</tpc></Note>
          </Chord>
          <Chord>
            <Tuplet>1</Tuplet>
            <durationType>eighth</durationType>
            <Note><pitch>64</pitch><tpc>18</tpc></Note>
          </Chord>
          <Chord>
            <durationType>quarter</durationType>
            <Note><pitch>65</pitch><tpc>13</tpc></Note>
          </Chord>
          <Chord>
            <durationType>quarter</durationType>
            <Note><pitch>67</pitch><tpc>15</tpc></Note>
          </Chord>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        let durations: [Fraction] = voice.elements.compactMap { el in
            guard case let .chord(c) = el else { return nil }
            return c.duration.asFraction
        }
        // Three triplet eighths (each 2/3 of an eighth = 1/12) and two
        // straight quarters (1/4) — total 1/4 + 1/4 + 1/4 = 3/4.
        #expect(durations.count == 5)
        #expect(durations[0] == Fraction(numerator: 1, denominator: 12))
        #expect(durations[1] == Fraction(numerator: 1, denominator: 12))
        #expect(durations[2] == Fraction(numerator: 1, denominator: 12))
        #expect(durations[3] == Fraction(numerator: 1, denominator: 4))
        #expect(durations[4] == Fraction(numerator: 1, denominator: 4))
        // The tuplet should be recorded against the first three
        // elements only.
        #expect(voice.tuplets.count == 1)
        let tuplet = voice.tuplets[0]
        #expect(tuplet.normalNotes == 2)
        #expect(tuplet.actualNotes == 3)
        #expect(tuplet.startIndex == 0)
        #expect(tuplet.endIndex == 2)
    }

    @Test func ms2SiblingTupletsDoNotNest() throws {
        // Three back-to-back MS2 triplets with no parent reference —
        // each <Tuplet id="…"> implicitly closes the previous one. If
        // we don't close on declaration, the stack accumulates and
        // later triplets get scaled by (2/3)^N (the 23/18-measure
        // outlier seen on the real input).
        let xml = """
        <voice>
          <Tuplet id="4">
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Chord><Tuplet>4</Tuplet><durationType>eighth</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><Tuplet>4</Tuplet><durationType>eighth</durationType>
            <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><Tuplet>4</Tuplet><durationType>eighth</durationType>
            <Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <Tuplet id="5">
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Chord><Tuplet>5</Tuplet><durationType>eighth</durationType>
            <Note><pitch>65</pitch><tpc>13</tpc></Note></Chord>
          <Chord><Tuplet>5</Tuplet><durationType>eighth</durationType>
            <Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
          <Chord><Tuplet>5</Tuplet><durationType>eighth</durationType>
            <Note><pitch>69</pitch><tpc>17</tpc></Note></Chord>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        // Six chords total, each one 1/12 (eighth scaled by 2/3), no
        // accidental 4/9 from accumulated nesting.
        let durations: [Fraction] = voice.elements.compactMap { el in
            guard case let .chord(c) = el else { return nil }
            return c.duration.asFraction
        }
        #expect(durations.count == 6)
        #expect(durations.allSatisfy { $0 == Fraction(numerator: 1, denominator: 12) })
        #expect(voice.tuplets.count == 2)
        #expect(voice.tuplets[0].startIndex == 0)
        #expect(voice.tuplets[0].endIndex == 2)
        #expect(voice.tuplets[1].startIndex == 3)
        #expect(voice.tuplets[1].endIndex == 5)
    }

    @Test func ms2TieAndEndSpannerOnNotes() throws {
        // MS2 stores ties as <Tie id="N"></Tie> on the start note and
        // <endSpanner id="N"/> on the end note (C++: MuseScore 2
        // libmscore/note.cpp Note::read). MS3+ wraps them in
        // <Spanner type="Tie"><next>/<prev>. Without the MS2 path,
        // every cross-bar tied note re-articulates instead of holding.
        let xml = """
        <voice>
          <Chord><durationType>quarter</durationType>
            <Note>
              <Tie id="2"></Tie>
              <pitch>63</pitch><tpc>11</tpc>
            </Note>
          </Chord>
          <Chord><durationType>quarter</durationType>
            <Note>
              <endSpanner id="2"/>
              <pitch>63</pitch><tpc>11</tpc>
            </Note>
          </Chord>
        </voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let voice = try Voice.decode(node)
        guard case let .chord(start) = voice.elements.first,
              case let .chord(end) = voice.elements.last,
              let n0 = start.notes.first,
              let n1 = end.notes.first
        else {
            Issue.record("expected two chord elements with one note each")
            return
        }
        #expect(n0.tieForward != nil)
        #expect(n0.tieBack == nil)
        #expect(n1.tieForward == nil)
        #expect(n1.tieBack != nil)
    }

    @Test func flatMeasureKeepsSingleVoiceWhenNoTrackTagPresent() throws {
        // Sanity check that the demux only kicks in when voice 1+ is
        // present — flat-form MS2 measures with only voice 0 should
        // still come through the single-implicit-voice fallback,
        // matching today's behaviour for the non-percussion staves.
        let xml = """
        <Measure number="1">
          <KeySig><concertKey>0</concertKey></KeySig>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
          </Chord>
          <Rest><durationType>quarter</durationType></Rest>
        </Measure>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let measure = try Measure.decode(node)
        #expect(measure.voices.count == 1)
        #expect(measure.voices[0].elements.count == 3)
    }
}
