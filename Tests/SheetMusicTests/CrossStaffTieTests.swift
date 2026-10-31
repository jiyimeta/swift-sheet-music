import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// MuseScore looks for a tie's partner in every track of the part (`searchTieNote`) and pairs the two halves it wrote
/// by `<location>` however far apart they are, so a piano score carries ties from one staff into the other
/// (`<staves>±1</staves>`) and ties that pass over other chords to a later one. Everything that paired the two ends
/// here walked one staff, and such a tie was dropped on import as two unmatched halves (`mscx.tie.unpairedSide`).
/// The shapes are MuseScore's own visual tests `vtest/scores/tie-18.mscz` (a note tied into the other staff) and
/// `tie-4.mscz` (a broken chord whose notes, moved to the other staff, each tie into the chord they sustain into).
struct CrossStaffTieTests {
    /// A two-staff part around the given `<Staff id="1">` and `<Staff id="2">` bodies.
    static func piano(_ upper: String, _ lower: String, version: String = "4.40") -> String {
        """
        <museScore version="\(version)">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Staff id="2"/>
              <Instrument><Channel/></Instrument>
            </Part>
            <Staff id="1">
        \(upper)
            </Staff>
            <Staff id="2">
        \(lower)
            </Staff>
          </Score>
        </museScore>
        """
    }

    /// One `<Note>` carrying the given tie spanners.
    static func note(_ pitch: Int, _ spanners: String...) -> String {
        "<Note>\(spanners.joined())<pitch>\(pitch)</pitch><tpc>14</tpc></Note>"
    }

    static func next(_ location: String) -> String {
        "<Spanner type=\"Tie\"><Tie/><next><location>\(location)</location></next></Spanner>"
    }

    static func prev(_ location: String) -> String {
        "<Spanner type=\"Tie\"><prev><location>\(location)</location></prev></Spanner>"
    }

    static func chord(_ duration: String, _ notes: String..., extra: String = "") -> String {
        "<Chord>\(extra)<durationType>\(duration)</durationType>\(notes.joined())</Chord>"
    }

    static func rest(_ duration: String) -> String {
        "<Rest><durationType>\(duration)</durationType></Rest>"
    }

    static let timeSig = "<TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>"

    static func measure(_ content: String...) -> String {
        "<Measure><voice>\(content.joined())</voice></Measure>"
    }

    /// tie-18's first bar: a C4 quarter in the upper staff held into the lower staff's C4 on beat 2.
    static let heldIntoTheOtherStaff = piano(
        measure(
            timeSig, chord("quarter", note(60, next("<staves>1</staves><fractions>1/4</fractions>"))),
            rest("quarter"), rest("half"),
        ),
        measure(
            timeSig, rest("quarter"),
            chord("quarter", note(60, prev("<staves>-1</staves><fractions>-1/4</fractions>"))), rest("half"),
        ),
    )

    /// tie-4's first bar: the lower staff's G3 sixteenth ties into its own G3 half on beat 2, over three sixteenths
    /// moved to the upper staff, each of which ties into the upper staff's half-note chord on beat 2.
    static let brokenChord = piano(
        measure(
            timeSig, rest("quarter"),
            chord(
                "half",
                note(60, prev("<staves>1</staves><fractions>-3/16</fractions>")),
                note(64, prev("<staves>1</staves><fractions>-1/8</fractions>")),
                note(67, prev("<staves>1</staves><fractions>-1/16</fractions>")),
            ),
            rest("quarter"),
        ),
        measure(
            timeSig,
            chord("16th", note(55, next("<fractions>1/4</fractions>"))),
            chord(
                "16th", note(60, next("<staves>-1</staves><fractions>3/16</fractions>")),
                extra: "<staffMove>-1</staffMove>",
            ),
            chord(
                "16th", note(64, next("<staves>-1</staves><fractions>1/8</fractions>")),
                extra: "<staffMove>-1</staffMove>",
            ),
            chord(
                "16th", note(67, next("<staves>-1</staves><fractions>1/16</fractions>")),
                extra: "<staffMove>-1</staffMove>",
            ),
            chord("half", note(55, prev("<fractions>-1/4</fractions>"))),
            rest("quarter"),
        ),
    )

    static func parse(_ xml: String) throws -> MSCXParseResult {
        try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
    }

    static func unpaired(_ result: MSCXParseResult) -> [ScoreDiagnostic] {
        result.diagnostics.filter { $0.code.hasPrefix("mscx.tie.unpairedSide") }
    }

    /// Every note of one staff, in measure / voice / element order.
    static func notes(_ score: Score, staff: Int) -> [Note] {
        score.parts[0].staves[staff].measures.flatMap { measure in
            measure.voices.flatMap { voice in
                voice.elements.flatMap { element -> [Note] in
                    guard case let .chord(chord) = element else { return [] }
                    return Array(chord.notes)
                }
            }
        }
    }

    static func noteOns(of pitch: Int, in midi: MidiFile) -> [Int] {
        midi.tracks.flatMap(\.events).compactMap { event in
            guard case let .noteOn(_, eventPitch, velocity) = event.event, eventPitch == pitch, velocity > 0
            else { return nil }
            return event.tick
        }
    }

    static func noteOffs(of pitch: Int, in midi: MidiFile) -> [Int] {
        midi.tracks.flatMap(\.events).compactMap { event in
            switch event.event {
            case let .noteOff(_, eventPitch, _) where eventPitch == pitch: event.tick
            case let .noteOn(_, eventPitch, 0) where eventPitch == pitch: event.tick
            default: nil
            }
        }
    }

    // MARK: - A note held into the other staff

    @Test func aTieIntoTheOtherStaffSurvivesImport() throws {
        let result = try Self.parse(Self.heldIntoTheOtherStaff)
        #expect(Self.unpaired(result).isEmpty)
        #expect(Self.notes(result.score, staff: 0).first?.tieForward != nil)
        #expect(Self.notes(result.score, staff: 1).first?.tieBack != nil)
    }

    @Test func aTieIntoTheOtherStaffPlaysAsOneHeldNote() throws {
        let midi = try MidiRenderer.render(score: Self.parse(Self.heldIntoTheOtherStaff).score)
        // Struck once on beat 1 and let go once, at the end of beat 2 — not struck again on beat 2.
        #expect(Self.noteOns(of: 60, in: midi) == [0])
        #expect(Self.noteOffs(of: 60, in: midi).count == 1)
        #expect(Self.noteOffs(of: 60, in: midi).allSatisfy { $0 > 480 })
    }

    @Test func theWriterNamesThePartnerStaffAsMuseScoreDoes() throws {
        let score = try Self.parse(Self.heldIntoTheOtherStaff).score
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        #expect(squeezed.contains("<next><location><staves>1</staves><fractions>1/4</fractions></location></next>"))
        #expect(squeezed.contains("<prev><location><staves>-1</staves><fractions>-1/4</fractions></location></prev>"))

        let reread = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        #expect(Self.unpaired(reread).isEmpty)
        #expect(DetachedTies.links(in: reread.score.parts[0]).count == 1)
    }

    @Test func theTiePlannerFindsThePartnerInTheOtherStaff() throws {
        let score = try Self.parse(Self.heldIntoTheOtherStaff).score
        let from = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        let to = try #require(TiePlanner.tiedNote(after: from, in: score))
        #expect(to.staff.staffIndexInPart == 1)
        #expect(TiePlanner.tiedNote(before: to, in: score) == from)
        #expect(TiePlanner.tieChain(containing: to, in: score) == [from, to])
    }

    @Test func anEditBesideATieIntoTheOtherStaffDoesNotSealIt() throws {
        let score = try Self.parse(Self.heldIntoTheOtherStaff).score
        var previous = score
        previous.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { $0.measures[0].lineBreak.toggle() }
        }
        #expect(DanglingTies.sealCommands(in: score, changedFrom: previous).isEmpty)
    }

    @Test func removingThePartnerInTheOtherStaffSealsTheTie() throws {
        let score = try Self.parse(Self.heldIntoTheOtherStaff).score
        // The lower staff's tied C4 becomes a rest; the upper staff's C4, untouched, must lose its `tieForward`.
        var edited = score
        edited.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 1) { staff in
                staff.measures[0].voices[0].elements.updateValue(at: 2) { element in
                    guard case var .chord(chord) = element else { return }
                    chord.notes = ChordNotes()
                    element = .chord(chord)
                }
            }
        }
        let seals = DanglingTies.sealCommands(in: edited, changedFrom: score)
        #expect(seals.count == 1)
    }

    // MARK: - A broken chord moved across the staves

    @Test func aBrokenChordKeepsEveryTie() throws {
        let result = try Self.parse(Self.brokenChord)
        #expect(Self.unpaired(result).isEmpty)
        #expect(Self.notes(result.score, staff: 0).allSatisfy { $0.tieBack != nil })
        let lower = Self.notes(result.score, staff: 1)
        #expect(lower.prefix(4).allSatisfy { $0.tieForward != nil })
        #expect(lower.last?.tieBack != nil)
        #expect(DetachedTies.links(in: result.score.parts[0]).count == 4)
    }

    @Test func aBrokenChordSoundsEachNoteOnceUntilTheChordEnds() throws {
        let midi = try MidiRenderer.render(score: Self.parse(Self.brokenChord).score)
        // Each note of the arpeggio is struck where it is written and held through the half-note chord it is tied
        // into — never struck again on beat 2.
        for (pitch, onset) in [(55, 0), (60, 120), (64, 240), (67, 360)] {
            #expect(Self.noteOns(of: pitch, in: midi) == [onset])
            let offs = Self.noteOffs(of: pitch, in: midi)
            #expect(offs.count == 1)
            #expect(offs.allSatisfy { $0 > 1440 - 10 && $0 <= 1440 })
        }
    }

    @Test func aBrokenChordRoundTripsThroughTheWriter() throws {
        let score = try Self.parse(Self.brokenChord).score
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        // The lower staff's G3 names its partner a quarter later, past the moved sixteenths — not the next chord.
        #expect(squeezed.contains("<next><location><fractions>1/4</fractions></location></next>"))
        #expect(squeezed.contains("<next><location><staves>-1</staves><fractions>3/16</fractions></location></next>"))
        #expect(squeezed.contains("<prev><location><staves>1</staves><fractions>-3/16</fractions></location></prev>"))
        let reread = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        #expect(Self.unpaired(reread).isEmpty)
        #expect(DetachedTies.links(in: reread.score.parts[0]).count == 4)
    }

    // MARK: - A tie over a hidden rest into the next bar

    /// MuseScore 3.02 wrote this into 制服のマネキン_bass.mscz: a tie from a note, over the hidden rest behind it, to
    /// the same pitch in the next bar.
    static let overAHiddenRest = """
    <museScore version="3.02">
      <Score>
        <Division>480</Division>
        <Part><Staff id="1"/><Instrument><Channel/></Instrument></Part>
        <Staff id="1">
          <Measure><voice>
            <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
            <Chord><durationType>half</durationType>
              <Note><Spanner type="Tie"><Tie/><next><location><measures>1</measures></location></next></Spanner>
                <pitch>69</pitch><tpc>17</tpc></Note>
            </Chord>
            <Rest><visible>0</visible><durationType>half</durationType></Rest>
          </voice></Measure>
          <Measure><voice>
            <Chord><durationType>whole</durationType>
              <Note><Spanner type="Tie"><prev><location><measures>-1</measures></location></prev></Spanner>
                <pitch>69</pitch><tpc>17</tpc></Note>
            </Chord>
          </voice></Measure>
        </Staff>
      </Score>
    </museScore>
    """

    @Test func aTieOverAHiddenRestSurvivesImportAndHolds() throws {
        let result = try Self.parse(Self.overAHiddenRest)
        #expect(Self.unpaired(result).isEmpty)
        let notes = Self.notes(result.score, staff: 0)
        #expect(notes.first?.tieForward != nil)
        #expect(notes.last?.tieBack != nil)
        let midi = try MidiRenderer.render(score: result.score)
        #expect(Self.noteOns(of: 69, in: midi) == [0])
    }

    // MARK: - Rules

    @Test func aTieInsideOneVoiceIsNotDetached() {
        let staff = [Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
        ])])]
        #expect(DetachedTies.links(in: [staff, staff]).isEmpty)
    }

    @Test func aTieDoesNotPassOverTheSamePitchStruckAgain() {
        // C4 tied forward, C4 struck afresh, then a C4 tied back: the tie cannot skip the middle note.
        let staff = [Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
        ])])]
        #expect(DetachedTies.links(in: [staff]).isEmpty)
    }
}
