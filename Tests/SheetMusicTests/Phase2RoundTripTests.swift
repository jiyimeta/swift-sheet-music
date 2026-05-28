import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for `<visible>` on Clef, KeySignature, TimeSignature,
/// and BarLine (Task 2.1). Each test encodes an element with `visible == false`,
/// re-parses the XML, and asserts the flag survives both directions of the
/// round-trip. Tests also confirm the default (visible) omits the tag entirely,
/// matching MuseScore's own serialisation behaviour.
struct Phase2RoundTripTests {
    // MARK: - BarLine

    @Test func barLineVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "BarLine",
            children: [XMLTreeNode(name: "visible", text: "0")],
        )
        let bar = try BarLine.decode(node)
        #expect(bar.visible == false)
        let reencoded = bar.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func barLineVisibleTrueOmitsTag() {
        let encoded = BarLine(subtype: nil).encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - Clef

    @Test func clefVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "Clef",
            children: [
                XMLTreeNode(name: "concertClefType", text: "G"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let clef = try Clef.decode(node)
        #expect(clef.visible == false)
        let reencoded = clef.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func clefVisibleTrueOmitsTag() {
        let encoded = Clef(concertClefType: "G").encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - KeySignature

    @Test func keySignatureVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "KeySig",
            children: [
                XMLTreeNode(name: "concertKey", text: "2"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let key = try KeySignature.decode(node)
        #expect(key.visible == false)
        let reencoded = key.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func keySignatureVisibleTrueOmitsTag() {
        let encoded = KeySignature(concertKey: 0).encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - TimeSignature

    @Test func timeSignatureVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "TimeSig",
            children: [
                XMLTreeNode(name: "sigN", text: "4"),
                XMLTreeNode(name: "sigD", text: "4"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let timeSig = try TimeSignature.decode(node)
        #expect(timeSig.visible == false)
        let reencoded = timeSig.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func timeSignatureVisibleTrueOmitsTag() {
        let encoded = TimeSignature(numerator: 4, denominator: 4).encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }
}
