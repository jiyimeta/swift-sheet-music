import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// MuseScore ties a note into whichever voice of the staff holds its pitch at the position the chord ends
/// (`searchTieNote`), so where voices part or merge a tie crosses voices. Everything that paired the two ends here
/// walked one voice, and such a tie was dropped on import as two unmatched halves (`mscx.tie.unpairedSide`, about one
/// in ten folino 2.1 users' files).
struct CrossVoiceTieTests {
    /// MuseScore's own `split184061-keep-tie.mscx`: a whole C5 in voice 2 of bar 1, tied into the whole C5 that voice
    /// 1 carries on in bar 2 (`<voices>-1</voices>`).
    private static func museScoreFixture() throws -> MSCXParseResult {
        let url = try #require(TestResources.url(forResource: "tie_cross_voice_split184061", withExtension: "mscx"))
        return try MSCXParser.parseWithDiagnostics(contentsOf: url)
    }

    /// One chord whose C ties into voice 2 of the next bar while its E stays in voice 1 — the two kinds side by side.
    private static let mixedChord = """
    <museScore version="4.40">
      <Score>
        <Division>480</Division>
        <Part>
          <Staff id="1"/>
          <Instrument><Channel/></Instrument>
        </Part>
        <Staff id="1">
          <Measure>
            <voice>
              <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
              <Chord>
                <durationType>whole</durationType>
                <Note>
                  <Spanner type="Tie">
                    <Tie/><next><location><voices>1</voices><measures>1</measures></location></next>
                  </Spanner>
                  <pitch>60</pitch><tpc>14</tpc>
                </Note>
                <Note>
                  <Spanner type="Tie"><Tie/><next><location><measures>1</measures></location></next></Spanner>
                  <pitch>64</pitch><tpc>18</tpc>
                </Note>
              </Chord>
            </voice>
          </Measure>
          <Measure>
            <voice>
              <Chord>
                <durationType>whole</durationType>
                <Note>
                  <Spanner type="Tie"><prev><location><measures>-1</measures></location></prev></Spanner>
                  <pitch>64</pitch><tpc>18</tpc>
                </Note>
              </Chord>
            </voice>
            <voice>
              <Chord>
                <durationType>whole</durationType>
                <Note>
                  <Spanner type="Tie">
                    <prev><location><voices>-1</voices><measures>-1</measures></location></prev>
                  </Spanner>
                  <pitch>60</pitch><tpc>14</tpc>
                </Note>
              </Chord>
            </voice>
          </Measure>
        </Staff>
      </Score>
    </museScore>
    """

    private static func notes(_ measure: Measure, voice: Int) -> [Note] {
        guard measure.voices.indices.contains(voice) else { return [] }
        return measure.voices[voice].elements.flatMap { element -> [Note] in
            guard case let .chord(chord) = element else { return [] }
            return Array(chord.notes)
        }
    }

    private static func noteOns(of pitch: Int, in midi: MidiFile) -> [Int] {
        midi.tracks.flatMap(\.events).compactMap { event in
            guard case let .noteOn(_, eventPitch, velocity) = event.event, eventPitch == pitch, velocity > 0
            else { return nil }
            return event.tick
        }
    }

    private static func noteOffs(of pitch: Int, in midi: MidiFile) -> [Int] {
        midi.tracks.flatMap(\.events).compactMap { event in
            switch event.event {
            case let .noteOff(_, eventPitch, _) where eventPitch == pitch: event.tick
            case let .noteOn(_, eventPitch, 0) where eventPitch == pitch: event.tick
            default: nil
            }
        }
    }

    @Test func aTieIntoAnotherVoiceSurvivesImport() throws {
        let result = try Self.museScoreFixture()
        #expect(!result.diagnostics.contains { $0.code == "mscx.tie.unpairedSide" })
        let measures = result.score.parts[0].staves[0].measures
        let held = try #require(Self.notes(measures[0], voice: 1).first { $0.pitch == 72 })
        let carried = try #require(Self.notes(measures[1], voice: 0).first { $0.pitch == 72 })
        #expect(held.tieForward != nil)
        #expect(carried.tieBack != nil)
    }

    @Test func aTieIntoAnotherVoicePlaysAsOneHeldNote() throws {
        let midi = try MidiRenderer.render(score: Self.museScoreFixture().score)
        // Two separate whole notes before: the C5 was struck again at bar 2.
        #expect(Self.noteOns(of: 72, in: midi) == [0])
    }

    @Test func aChordKeepsBothItsTieIntoItsOwnVoiceAndItsTieIntoAnother() throws {
        let result = try MSCXParser.parseWithDiagnostics(Data(Self.mixedChord.utf8))
        #expect(!result.diagnostics.contains { $0.code == "mscx.tie.unpairedSide" })
        let measures = result.score.parts[0].staves[0].measures
        let first = Self.notes(measures[0], voice: 0)
        #expect(first.map(\.pitch) == [60, 64])
        #expect(first.allSatisfy { $0.tieForward != nil })
        #expect(Self.notes(measures[1], voice: 0).first?.tieBack != nil)
        #expect(Self.notes(measures[1], voice: 1).first?.tieBack != nil)

        // Each pitch is held through both bars and let go once, at the end of the second: a cross-voice tie left in
        // its voice's tie queue handed C's pitch to E's continuation, leaving E sounding and C released twice.
        let midi = try MidiRenderer.render(score: result.score)
        let bar = 4 * result.score.division
        for pitch in [60, 64] {
            #expect(Self.noteOns(of: pitch, in: midi) == [0])
            let offs = Self.noteOffs(of: pitch, in: midi)
            #expect(offs.count == 1)
            #expect(offs.allSatisfy { $0 > bar })
        }
    }

    @Test func theWriterNamesThePartnerVoiceAsMuseScoreDoes() throws {
        // MuseScore wrote split184061 with `<voices>-1</voices><measures>1</measures>` on the `<next>` side and
        // `<voices>1</voices><measures>-1</measures>` on the `<prev>` side. Without `<voices>` the location named a
        // chord in the tie's own voice, and MuseScore dropped the tie from a file this package wrote.
        let xml = try #require(try String(data: MSCXEncoder.encode(Self.museScoreFixture().score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        #expect(squeezed.contains("<next><location><voices>-1</voices><measures>1</measures></location></next>"))
        #expect(squeezed.contains("<prev><location><voices>1</voices><measures>-1</measures></location></prev>"))

        let reread = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        #expect(!reread.diagnostics.contains { $0.code == "mscx.tie.unpairedSide" })
        #expect(CrossVoiceTies.links(in: reread.score.parts[0].staves[0].measures).count == 1)
    }

    @Test func aMixedChordWritesOnlyItsCrossVoiceTieWithVoices() throws {
        let score = try MSCXParser.parse(Data(Self.mixedChord.utf8))
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        // C (into voice 2) and E (into voice 1) leave the same chord; only C's location names another voice.
        #expect(squeezed.components(separatedBy: "<voices>").count - 1 == 2)
        #expect(squeezed.contains("<next><location><voices>1</voices><measures>1</measures></location></next>"))
        #expect(squeezed.contains("<prev><location><voices>-1</voices><measures>-1</measures></location></prev>"))
    }

    @Test func theTiePlannerFindsThePartnerInTheOtherVoice() throws {
        let score = try Self.museScoreFixture().score
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let measures = score.parts[0].staves[0].measures
        let element = try #require(measures[0].voices[1].elements.firstIndex { element in
            if case let .chord(chord) = element { return chord.notes.contains { $0.pitch == 72 } }
            return false
        })
        let from = NoteID(
            staff: staff, measureIndex: 0, voiceIndex: 1, elementIndex: element, noteIndexInChord: 0,
        )
        let to = try #require(TiePlanner.tiedNote(after: from, in: score))
        #expect(to.measureIndex == 1)
        #expect(to.voiceIndex == 0)
        #expect(TiePlanner.tiedNote(before: to, in: score) == from)
    }

    @Test func anEditBesideATieIntoAnotherVoiceDoesNotSealIt() throws {
        let score = try MSCXParser.parseWithDiagnostics(Data(Self.mixedChord.utf8)).score
        // Any change in bar 1 puts bars 1 and 2 under the dangling-tie scan.
        var previous = score
        previous.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].lineBreak.toggle()
            }
        }
        #expect(DanglingTies.sealCommands(in: score, changedFrom: previous).isEmpty)
    }

    @Test func linksNameTheTwoEnds() throws {
        let measures = try Self.museScoreFixture().score.parts[0].staves[0].measures
        let links = CrossVoiceTies.links(in: measures)
        #expect(links.count == 1)
        #expect(links.first?.from.measure == 0)
        #expect(links.first?.from.voice == 1)
        #expect(links.first?.to.measure == 1)
        #expect(links.first?.to.voice == 0)
    }

    @Test func aTieInsideOneVoiceIsNotALink() {
        // Same pitch held in voice 1 and struck afresh in voice 2: the tie stays in voice 1.
        let tied = Measure(voices: [
            Voice(elements: [
                .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)])),
                .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
            ]),
            Voice(elements: [
                .chord(Chord(duration: .half, notes: [Note(pitch: 55, tpc: 15)])),
                .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
            ]),
        ])
        #expect(CrossVoiceTies.links(in: [tied]).isEmpty)
    }
}
