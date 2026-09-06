@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite("Element placement MSCX")
struct ElementPlacementMSCXTests {
    @Test func nonSpannerPlacementsRoundTrip() {
        let fingering = Fingering.decode(XMLTreeNode(
            name: "Fingering",
            children: [
                XMLTreeNode(name: "text", text: "1"),
                XMLTreeNode(name: "placement", text: "above"),
            ],
        ))
        #expect(fingering.elementProperties.placement == .above)
        #expect(fingering.preservedMarkup.isEmpty)
        let encodedFingering = fingering.encode()
        #expect(encodedFingering.all("placement").count == 1)
        #expect(encodedFingering.first("placement")?.text == "above")

        let capo = Capo.decode(XMLTreeNode(
            name: "Capo",
            children: [
                XMLTreeNode(name: "text", text: "Capo 2"),
                XMLTreeNode(name: "placement", text: "below"),
            ],
        ))
        #expect(capo.elementProperties.placement == .below)
        #expect(capo.preservedMarkup.isEmpty)
        let encodedCapo = capo.encode()
        #expect(encodedCapo.all("placement").count == 1)
        #expect(encodedCapo.first("placement")?.text == "below")
    }

    @Test func absentPlacementStaysNilAndEmitsNothing() {
        let fingering = Fingering.decode(XMLTreeNode(
            name: "Fingering",
            children: [XMLTreeNode(name: "text", text: "1")],
        ))
        #expect(fingering.elementProperties.placement == nil)
        #expect(fingering.encode().all("placement").isEmpty)
    }

    @Test func unknownPlacementIsDroppedInsteadOfPreserved() {
        let fingering = Fingering.decode(XMLTreeNode(
            name: "Fingering",
            children: [
                XMLTreeNode(name: "text", text: "1"),
                XMLTreeNode(name: "placement", text: "middle"),
            ],
        ))
        #expect(fingering.elementProperties.placement == nil)
        let preservedPlacements = fingering.preservedMarkup.filter {
            $0.name == "placement"
        }
        #expect(preservedPlacements.isEmpty)
        #expect(fingering.encode().all("placement").isEmpty)
    }
}
