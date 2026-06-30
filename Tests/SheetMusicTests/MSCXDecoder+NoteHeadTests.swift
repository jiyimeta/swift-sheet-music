import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct HeadTypeDecodeTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    /// MS2 integer codes 0–13 must round-trip to their MS4 token equivalents.
    /// Code 13 was historically serialised as "alt-brevis"; MS4 normalises it to "altbrevis".
    @Test func ms2CodeNormalizesToMS4Token() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>13</head></Note>"
        let note = try parseNote(xml)
        #expect(note.headType == "altbrevis")
    }

    /// An out-of-range integer code must emit a diagnostic and drop the head (return nil).
    @Test func unknownIntegerCodeWarnsAndDrops() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>99</head></Note>"
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try parseNote(xml)
        }
        #expect(collector.entries.contains { $0.code == "mscx.note.unsupportedHeadType" })
        #expect(note.headType == nil)
    }

    /// Known MS4 string tokens must pass through without a diagnostic.
    @Test func knownStringTokenPassesThrough() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>xcircle</head></Note>"
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try parseNote(xml)
        }
        #expect(note.headType == "xcircle")
        #expect(collector.entries.isEmpty)
    }

    /// An unknown string token must emit a diagnostic and drop the head.
    @Test func unknownStringTokenWarnsAndDrops() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>bogus-head</head></Note>"
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try parseNote(xml)
        }
        #expect(collector.entries.contains { $0.code == "mscx.note.unsupportedHeadType" })
        #expect(note.headType == nil)
    }

    /// "custom" is intentional (user-defined head) — must pass through silently.
    @Test func customTokenPassesThroughSilently() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><head>custom</head></Note>"
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try parseNote(xml)
        }
        #expect(note.headType == "custom")
        #expect(collector.entries.isEmpty)
    }
}
