import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Tests for redundant auto-accidental suppression
/// (`Score.suppressingRedundantAccidentals()`) and `<role>` decoding.
struct AccidentalVisibilityTests {
    // MARK: - Builders

    /// Build a single-staff score from a list of measures, where each
    /// measure is a list of (note, duration) entries forming voice 0.
    /// An optional concert key is declared at the start of measure 0.
    private static func score(
        key: Int? = nil,
        measures: [[(note: Note, duration: NoteDuration)]],
    ) -> Score {
        var builtMeasures: [Measure] = []
        for (measureIndex, entries) in measures.enumerated() {
            var elements: [VoiceElement] = []
            if measureIndex == 0, let key {
                elements.append(.keySignature(KeySignature(concertKey: key)))
            }
            for entry in entries {
                elements.append(.chord(Chord(
                    duration: entry.duration, notes: [entry.note],
                )))
            }
            builtMeasures.append(Measure(voices: [Voice(elements: elements)]))
        }
        let staff = Staff(measures: builtMeasures)
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// The accidental on staff 0, measure `m`, the `c`-th chord (ignoring
    /// any leading key signature), note 0.
    private static func accidental(
        _ score: Score, measure m: Int, chord c: Int,
    ) -> Accidental? {
        let elements = score.parts[0].staves[0].measures[m].voices[0].elements
        let chords = elements.compactMap { element -> Chord? in
            if case let .chord(chord) = element { return chord }
            return nil
        }
        return chords[c].notes[0].accidental
    }

    /// Concrete notes (octave 4 unless noted). pitch / tpc pairs verified
    /// against MuseScore's TPC line-of-fifths.
    private static func cSharp4(role: AccidentalRole = .auto) -> Note {
        Note(pitch: 61, tpc: 21, accidental: .sharp, accidentalRole: role)
    }

    private static func cNatural4(role: AccidentalRole = .auto) -> Note {
        Note(pitch: 60, tpc: 14, accidental: .natural, accidentalRole: role)
    }

    private static func eNatural4(role: AccidentalRole = .auto) -> Note {
        Note(pitch: 64, tpc: 18, accidental: .natural, accidentalRole: role)
    }

    private static func fSharp4(role: AccidentalRole = .auto) -> Note {
        Note(pitch: 66, tpc: 20, accidental: .sharp, accidentalRole: role)
    }

    private static func eFlat4(role: AccidentalRole = .auto) -> Note {
        Note(pitch: 63, tpc: 11, accidental: .flat, accidentalRole: role)
    }

    // MARK: - Suppress redundant AUTO

    @Test("E natural in C major (auto) → accidental removed")
    func redundantNaturalInCMajorSuppressed() {
        let s = Self.score(measures: [[(Self.eNatural4(), .quarter)]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == nil)
    }

    @Test("Second C# after first C# (both auto) → second removed, first kept")
    func secondSharpSuppressedFirstKept() {
        let s = Self.score(measures: [[
            (Self.cSharp4(), .quarter),
            (Self.cSharp4(), .quarter),
        ]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == .sharp)
        #expect(Self.accidental(out, measure: 0, chord: 1) == nil)
    }

    @Test("F# in G major (auto) → removed")
    func keySharpSuppressed() {
        let s = Self.score(key: 1, measures: [[(Self.fSharp4(), .quarter)]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == nil)
    }

    // MARK: - KEEP must NOT suppress

    @Test("First C# in C major → kept")
    func neededSharpKept() {
        let s = Self.score(measures: [[(Self.cSharp4(), .quarter)]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == .sharp)
    }

    @Test("Natural cancels prior sharp in same measure → kept")
    func cancellingNaturalKept() {
        let s = Self.score(measures: [[
            (Self.cSharp4(), .quarter),
            (Self.cNatural4(), .quarter),
        ]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == .sharp)
        // The natural cancels the prior sharp on the same line — needed.
        #expect(Self.accidental(out, measure: 0, chord: 1) == .natural)
    }

    @Test("Redundant accidental with USER role → kept")
    func userRoleAlwaysKept() {
        let s = Self.score(measures: [[(Self.eNatural4(role: .user), .quarter)]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == .natural)
    }

    @Test("After measure boundary the needed accidental reappears (state reset)")
    func stateResetsAtBarline() {
        let s = Self.score(measures: [
            [(Self.cSharp4(), .whole)],
            [(Self.cSharp4(), .whole)],
        ])
        let out = s.suppressingRedundantAccidentals()
        // Both kept: the second measure starts a fresh state, so its C#
        // is again needed against the C-major key signature.
        #expect(Self.accidental(out, measure: 0, chord: 0) == .sharp)
        #expect(Self.accidental(out, measure: 1, chord: 0) == .sharp)
    }

    // MARK: - Regression: every accidental needed → none removed

    @Test("All-needed accidentals → none removed")
    func allNeededUnchanged() {
        let s = Self.score(measures: [[
            (Self.cSharp4(), .quarter), // C# vs C-major C♮ — needed
            (Self.eFlat4(), .quarter), // E♭ vs C-major E♮ — needed
            (Self.fSharp4(), .quarter), // F# vs C-major F♮ — needed
        ]])
        let out = s.suppressingRedundantAccidentals()
        #expect(Self.accidental(out, measure: 0, chord: 0) == .sharp)
        #expect(Self.accidental(out, measure: 0, chord: 1) == .flat)
        #expect(Self.accidental(out, measure: 0, chord: 2) == .sharp)
        /// Pitches must be untouched.
        func notePitch(measure m: Int, chord c: Int) -> Int {
            let chords = out.parts[0].staves[0].measures[m].voices[0].elements
                .compactMap { e -> Chord? in
                    if case let .chord(chord) = e { return chord }
                    return nil
                }
            return chords[c].notes[0].pitch
        }
        #expect(notePitch(measure: 0, chord: 0) == 61)
        #expect(notePitch(measure: 0, chord: 1) == 63)
        #expect(notePitch(measure: 0, chord: 2) == 66)
    }

    @Test("Bracket is cleared together with the suppressed accidental")
    func bracketClearedOnSuppress() {
        var note = Self.eNatural4()
        note.accidentalBracket = .parenthesis
        let s = Self.score(measures: [[(note, .quarter)]])
        let out = s.suppressingRedundantAccidentals()
        let chords = out.parts[0].staves[0].measures[0].voices[0].elements
            .compactMap { e -> Chord? in
                if case let .chord(chord) = e { return chord }
                return nil
            }
        #expect(chords[0].notes[0].accidental == nil)
        #expect(chords[0].notes[0].accidentalBracket == .none)
    }

    // MARK: - Decode <role>

    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    @Test("<role>1</role> decodes to .user")
    func decodesUserRole() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype><role>1</role></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidentalRole == .user)
    }

    @Test("Absent <role> decodes to .auto")
    func absentRoleDefaultsToAuto() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidentalRole == .auto)
    }

    @Test("<role>0</role> decodes to .auto")
    func explicitZeroRoleIsAuto() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype><role>0</role></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidentalRole == .auto)
    }

    @Test("Note with no <Accidental> defaults to .auto role")
    func noAccidentalElementDefaultsToAuto() throws {
        let note = try parseNote("<Note><pitch>60</pitch><tpc>14</tpc></Note>")
        #expect(note.accidentalRole == .auto)
    }
}
