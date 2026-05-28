import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for `<visible>` on Note, Chord, Rest, and Dynamic
/// (Task 1.2). Each test encodes an element with `visible == false`, re-parses
/// the XML, and asserts the flag survives both directions of the round-trip.
/// Tests also confirm the default (visible) omits the tag entirely, matching
/// MuseScore's own serialisation behaviour.
struct Phase1RoundTripTests {
    // MARK: - Dynamic

    @Test func dynamicVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Dynamic",
            children: [
                XMLTreeNode(name: "subtype", text: "f"),
                XMLTreeNode(name: "velocity", text: "96"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let dyn = try Dynamic.decode(node)
        #expect(dyn.visible == false)
        let reencoded = dyn.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func dynamicVisibleTrueOmitsTag() {
        let encoded = Dynamic(subtype: "f", velocity: 96).encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - Note

    @Test func noteVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Note",
            children: [
                XMLTreeNode(name: "pitch", text: "60"),
                XMLTreeNode(name: "tpc", text: "14"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let note = try Note.decode(node)
        #expect(note.visible == false)
        let reencoded = note.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func noteVisibleTrueOmitsTag() {
        let encoded = Note(pitch: 60, tpc: 14).encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - Chord

    @Test func chordVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "visible", text: "0"),
                XMLTreeNode(
                    name: "Note",
                    children: [
                        XMLTreeNode(name: "pitch", text: "60"),
                        XMLTreeNode(name: "tpc", text: "14"),
                    ],
                ),
            ],
        )
        let chord = try Chord.decode(node)
        #expect(chord.visible == false)
        let reencoded = chord.encodeAsChord()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func chordVisibleTrueOmitsTag() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        )
        let encoded = chord.encodeAsChord()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - Chord <Stem><visible>

    @Test func stemVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "eighth"),
                XMLTreeNode(name: "Stem", children: [
                    XMLTreeNode(name: "visible", text: "0"),
                ]),
                XMLTreeNode(
                    name: "Note",
                    children: [
                        XMLTreeNode(name: "pitch", text: "60"),
                        XMLTreeNode(name: "tpc", text: "14"),
                    ],
                ),
            ],
        )
        let chord = try Chord.decode(node)
        #expect(chord.stemVisible == false)
        let reencoded = chord.encodeAsChord()
        let stem = reencoded.first("Stem")
        #expect(stem != nil)
        #expect(stem?.first("visible")?.text == "0")
    }

    @Test func stemVisibleTrueOmitsTag() {
        let chord = Chord(
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        )
        let encoded = chord.encodeAsChord()
        #expect(!encoded.children.contains(where: { $0.name == "Stem" }))
    }

    // MARK: - Rest (decoded via MSCXRestDecoder, encoded via encodeAsRest)

    @Test func restVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Rest",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let rest = try MSCXRestDecoder.decode(node)
        #expect(rest.visible == false)
        let reencoded = rest.encodeAsRest()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func restVisibleTrueOmitsTag() {
        let encoded = Chord(duration: .quarter, notes: []).encodeAsRest()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }
}
