import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<Note>` fragments, not whole scores: `Note.decode` is the unit under test,
/// and the fixture-level round trip is the preservation gate's job.
private func parseNote(_ inner: String) throws -> Note {
    let root = try XMLTreeParser.parse(Data("<Note>\(inner)</Note>".utf8))
    return try Note.decode(root)
}

@Suite("Fingering model")
struct FingeringModelTests {
    @Test(arguments: [
        (Fingering.Role.leftHandGuitar, "guitar_fingering_lh"),
        (Fingering.Role.rightHandGuitar, "guitar_fingering_rh"),
        (Fingering.Role.stringNumber, "string_number"),
    ])
    func namedRolesRoundTripTheirToken(_ role: Fingering.Role, _ token: String) {
        #expect(role.mscxToken == token)
        #expect(Fingering.Role(mscxToken: token) == role)
    }

    @Test func plainFingeringHasNoToken() {
        // MuseScore's writer omits <style> when it equals the element default,
        // so the absent tag and the explicit spelling mean the same role.
        #expect(Fingering.Role.fingering.mscxToken == nil)
        #expect(Fingering.Role(mscxToken: "fingering") == .fingering)
    }

    @Test func unrecognizedStyleIsKeptRatherThanDroppedToTheDefault() {
        let role = Fingering.Role(mscxToken: "user_1")
        #expect(role == .other(style: "user_1"))
        #expect(role.mscxToken == "user_1")
    }

    @Test func noteDefaultsToNoFingerings() {
        #expect(Note(pitch: 60, tpc: 14).fingerings.isEmpty)
    }

    @Test func noteStoresSeveralFingerings() {
        let note = Note(pitch: 60, tpc: 14, fingerings: [
            Fingering(text: "2", role: .leftHandGuitar),
            Fingering(text: "3", role: .stringNumber),
        ])
        #expect(note.fingerings.map(\.text) == ["2", "3"])
        #expect(note.fingerings.map(\.role) == [.leftHandGuitar, .stringNumber])
    }

    private func fingerprint(_ fingerings: [Fingering]) -> UInt64 {
        var hasher = FNV1a()
        hasher.combineOccupied(fingerings, tag: 36)
        return hasher.value
    }

    @Test func fingerprintSeparatesRolesAndText() {
        #expect(
            fingerprint([.init(text: "1")]) != fingerprint([.init(text: "2")]),
        )
        #expect(
            fingerprint([.init(text: "1")])
                != fingerprint([.init(text: "1", role: .stringNumber)]),
        )
    }

    @Test func fingerprintOfNoFingeringsFeedsNothing() {
        var hasher = FNV1a()
        let before = hasher.value
        hasher.combineOccupied([] as [Fingering], tag: 36)
        #expect(hasher.value == before)
    }
}

@Suite("Fingering MSCX round trip")
struct FingeringMSCXTests {
    @Test func decodesABareFingering() throws {
        let note = try parseNote("""
        <Fingering><text>1</text></Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(note.fingerings == [Fingering(text: "1")])
    }

    @Test func decodesStyledFingeringsInDocumentOrder() throws {
        let note = try parseNote("""
        <Fingering><style>guitar_fingering_lh</style><text>2</text></Fingering>
        <Fingering><style>string_number</style><text>3</text></Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(note.fingerings.map(\.role) == [.leftHandGuitar, .stringNumber])
        #expect(note.fingerings.map(\.text) == ["2", "3"])
    }

    @Test func flattensInlineMarkupInTheText() throws {
        // MuseScore wraps a resized fingering as <text><font size="8"/>2</text>.
        // The font override is lost with the rest of the inline-markup gap
        // (parity doc §7.1); the digit the reader sees is what is modeled.
        let note = try parseNote("""
        <Fingering><text><font size="8"/>2</text></Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(note.fingerings.map(\.text) == ["2"])
    }

    @Test func modelsPlacementAndOffset() throws {
        let note = try parseNote("""
        <Fingering>
          <text>1</text>
          <placement>below</placement>
          <offset x="0" y="1.5"/>
        </Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        let fingering = try #require(note.fingerings.first)
        #expect(fingering.preservedMarkup.isEmpty)
        #expect(fingering.elementProperties.placement == .below)
        #expect(fingering.elementProperties.offset == ScoreOffset(x: 0, y: 1.5))
    }

    @Test func fingeringIsNotAlsoPreservedOnTheNote() throws {
        let note = try parseNote("""
        <Fingering><text>1</text></Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(!note.preservedMarkup.map(\.name).contains("Fingering"))
    }

    @Test func encodesTheBareFormWithoutAStyleTag() {
        let node = Fingering(text: "1").encode()
        #expect(node.name == "Fingering")
        #expect(node.children.map(\.name) == ["text"])
        #expect(node.first("text")?.text == "1")
    }

    @Test func encodesStyleBeforeText() {
        let node = Fingering(text: "p", role: .rightHandGuitar).encode()
        #expect(node.children.map(\.name) == ["style", "text"])
        #expect(node.first("style")?.text == "guitar_fingering_rh")
    }

    @Test func noteEncodesFingeringsBeforePitch() throws {
        let note = Note(pitch: 60, tpc: 14, fingerings: [Fingering(text: "1")])
        let names = note.encode().children.map(\.name)
        let fingering = try #require(names.firstIndex(of: "Fingering"))
        let pitch = try #require(names.firstIndex(of: "pitch"))
        #expect(fingering < pitch)
    }

    @Test func roundTripsEverythingModeled() throws {
        let decoded = try parseNote("""
        <Fingering><style>string_number</style><text>3</text><placement>above</placement></Fingering>
        <Fingering><text>1</text></Fingering>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        let reDecoded = try Note.decode(decoded.encode())
        #expect(reDecoded.fingerings == decoded.fingerings)
    }

    /// The preservation gate `continue`s past a fixture it cannot parse, so
    /// this is what proves `fingerings.mscx` is actually being read.
    @Test func fixtureDecodesEveryFingeringItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fingerings"))
        let notes = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap { element -> Chord? in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
            .flatMap { Array($0.notes) }
        #expect(notes.flatMap(\.fingerings).map(\.text) == ["1", "3", "2", "i", "5"])
        #expect(notes.flatMap(\.fingerings).map(\.role) == [
            .fingering, .stringNumber, .leftHandGuitar, .rightHandGuitar,
            .other(style: "user_1"),
        ])
    }
}
