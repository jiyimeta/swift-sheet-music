import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterFaçadeTests {
    /// Minimal valid SMF: format 0, division 480, one MTrk containing
    /// only an end-of-track meta event.
    private static let emptySMFBytes = Data([
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00,
    ])

    @Test func parsesEmptyFormat0AsEmptyScore() throws {
        let score = try MidiImporter.parse(Self.emptySMFBytes)
        #expect(score.division == 480)
        #expect(score.parts.isEmpty)
        #expect(score.staves.isEmpty)
    }

    @Test func usesSourceFilenameAsTitle() throws {
        let score = try MidiImporter.parse(Self.emptySMFBytes, sourceFilename: "MySong")
        #expect(score.metaTags["workTitle"] == "MySong")
    }

    @Test func emptySourceFilenameMeansNoTitle() throws {
        let score = try MidiImporter.parse(Self.emptySMFBytes, sourceFilename: "")
        #expect(score.metaTags["workTitle"] == nil)
    }
}
