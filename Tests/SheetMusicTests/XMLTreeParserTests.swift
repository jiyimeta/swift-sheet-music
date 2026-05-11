import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct XMLTreeParserTests {
    @Test func parsesSimpleNestedDocument() throws {
        let xml = #"<?xml version="1.0"?><root><a>hi</a><b key="v"/></root>"#
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.name == "root")
        #expect(root.children.count == 2)
        #expect(root.first("a")?.text == "hi")
        #expect(root.first("b")?.attributes["key"] == "v")
    }

    @Test func preservesChildOrder() throws {
        let xml = "<r><x/><y/><x/></r>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.children.map(\.name) == ["x", "y", "x"])
    }

    @Test func collectsRepeatedChildren() throws {
        let xml = "<r><n>1</n><n>2</n><n>3</n></r>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        #expect(root.all("n").map(\.text) == ["1", "2", "3"])
    }

    @Test func reportsInvalidXMLAsError() {
        let xml = "<root><unclosed></root>"
        #expect(throws: SheetMusicError.self) {
            try XMLTreeParser.parse(Data(xml.utf8))
        }
    }
}
