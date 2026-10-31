import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct MS2GlissandoTests {
    /// MuseScore 2 ends a glissando with the same note-level `<endSpanner id="N"/>` it ends a tie with. Read as a tie
    /// end, it found no `<Tie>` partner and was reported as `mscx.tie.unpairedSide` (36 of 40 corpus files that
    /// reported it), while the `<Glissando>` itself was kept only as unread markup — neither drawn nor played.
    @Test func ms2GlissandoEndIsNotATieEnd() throws {
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
                <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
                <Chord><durationType>quarter</durationType>
                  <Note><Tie id="2"></Tie><pitch>63</pitch><tpc>11</tpc></Note>
                </Chord>
                <Chord><durationType>quarter</durationType>
                  <Note><endSpanner id="2"/><pitch>63</pitch><tpc>11</tpc></Note>
                </Chord>
                <Chord><durationType>quarter</durationType>
                  <Note><pitch>48</pitch><tpc>14</tpc>
                    <Glissando id="3"><text>gliss.</text><subtype>1</subtype></Glissando>
                  </Note>
                </Chord>
                <Chord><durationType>quarter</durationType>
                  <Note><pitch>60</pitch><tpc>14</tpc><endSpanner id="3"/></Note>
                </Chord>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let result = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        #expect(!result.diagnostics.contains { $0.code == "mscx.tie.unpairedSide" })
        let notes = result.score.parts[0].staves[0].measures[0].voices[0].elements.compactMap { element -> Note? in
            guard case let .chord(chord) = element else { return nil }
            return chord.notes.first
        }
        #expect(notes.map { $0.tieForward != nil } == [true, false, false, false])
        #expect(notes.map { $0.tieBack != nil } == [false, true, false, false])
        #expect(notes[2].glissando?.visualType == .wavy)
        #expect(notes[3].glissando == nil)
    }
}
