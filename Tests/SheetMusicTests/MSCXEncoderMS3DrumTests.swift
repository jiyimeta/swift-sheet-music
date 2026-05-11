import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 Drum target")
struct MSCXEncoderMS3DrumTests {
    @Test("v3 percussion chord emits StemDirection and head")
    func v3DrumChordEmitsStemDirectionAndHead() throws {
        let drumNote = Note(pitch: 38, tpc: 14, headType: "slash")
        let chord = Chord(
            duration: .quarter,
            notes: [drumNote],
        )
        let xml = chord.encodeAsChord(
            options: .init(targetVersion: .v3),
            staffGroup: "percussion",
            voiceIndex: 0,
        )
        let firstChild = try #require(xml.children.first)
        #expect(firstChild.name == "StemDirection")
        #expect(firstChild.text == "up")
        let note = try #require(xml.first("Note"))
        #expect(note.first("head")?.text == "slash")
    }

    @Test("v3 percussion chord on voice 1 emits StemDirection down")
    func v3DrumChordVoice1StemDown() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 36, tpc: 14)],
        )
        let xml = chord.encodeAsChord(
            options: .init(targetVersion: .v3),
            staffGroup: "percussion",
            voiceIndex: 1,
        )
        let firstChild = try #require(xml.children.first)
        #expect(firstChild.name == "StemDirection")
        #expect(firstChild.text == "down")
    }

    @Test("v3 percussion note without headType defaults to normal")
    func v3DrumNoteHeadDefaultsToNormal() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 36, tpc: 14)],
        )
        let xml = chord.encodeAsChord(
            options: .init(targetVersion: .v3),
            staffGroup: "percussion",
            voiceIndex: 1,
        )
        let note = try #require(xml.first("Note"))
        #expect(note.first("head")?.text == "normal")
    }

    @Test("v4 percussion chord emits no StemDirection")
    func v4DrumChordOmitsStemDirection() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 38, tpc: 14)],
        )
        let xml = chord.encodeAsChord(
            options: .init(targetVersion: .v4),
            staffGroup: "percussion",
            voiceIndex: 0,
        )
        #expect(!xml.children.map(\.name).contains("StemDirection"))
    }

    @Test("v3 pitched-staff chord emits no StemDirection")
    func v3PitchedStaffChordOmitsStemDirection() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let xml = chord.encodeAsChord(
            options: .init(targetVersion: .v3),
            staffGroup: "pitched",
            voiceIndex: 0,
        )
        #expect(!xml.children.map(\.name).contains("StemDirection"))
    }
}
