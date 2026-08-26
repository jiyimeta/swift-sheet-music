import Foundation
@testable import SheetMusicXMLTools
import Testing

@Suite("Android smoke tests")
struct AndroidSmokeTests {
    @Test("XMLTreeParser can parse a minimal document")
    func parseMinimalXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
            <child attr="value">text</child>
        </root>
        """
        let data = Data(xml.utf8)
        let root = try XMLTreeParser.parse(data)
        #expect(root.name == "root")
        #expect(root.children.first?.name == "child")
        #expect(root.children.first?.attributes["attr"] == "value")
    }

    @Test("test resource helper resolves bundled resources")
    func bundleModule() {
        let url = TestResources.url(forResource: "midi01", withExtension: "mscx")
        #expect(url != nil, "midi01.mscx must be locatable via TestResources")
    }
}
