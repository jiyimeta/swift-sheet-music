import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite("EID persistence")
struct EIDPersistenceTests {
    @Test("a MuseScore-written identifier decodes to the same halves it encodes from")
    func childRoundTrips() throws {
        let eid = EID(first: 1, second: 1)
        let node = try #require(EIDXML.node(for: eid))
        #expect(node.name == "eid")
        #expect(node.text == "B_B") // the value in Tests/SheetMusicTests/Resources/midi01.mscx
        #expect(EIDXML.decode(from: XMLTreeNode(name: "Chord", children: [node])) == eid)
    }

    @Test("an absent or malformed child is not an identifier")
    func absentChildIsInvalid() {
        #expect(EIDXML.decode(from: XMLTreeNode(name: "Chord", children: [])) == .invalid)
        let malformed = XMLTreeNode(name: "Chord", children: [XMLTreeNode(name: "eid", text: "_")])
        #expect(EIDXML.decode(from: malformed) == .invalid)
    }

    @Test("an unassigned slot writes no child")
    func unassignedWritesNothing() {
        #expect(EIDXML.node(for: .invalid) == nil)
    }
}
