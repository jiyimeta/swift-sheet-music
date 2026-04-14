import Foundation
@testable import MuseScoreParser
import Testing

@Suite struct MidiExportTests {
    @Test func midi01() throws { try assertExportMatchesReference(name: "midi01") }
    @Test func midi02() throws { try assertExportMatchesReference(name: "midi02") }
    @Test func midi03() throws { try assertExportMatchesReference(name: "midi03") }
    @Test func midiPortExport() throws { try assertExportMatchesReference(name: "testMidiPort") }
    @Test func midiArpeggio() throws { try assertExportMatchesReference(name: "testArpeggio") }
    @Test func midiMutedUnison() throws { try assertExportMatchesReference(name: "testMutedUnison") }
    @Test func midiMeasureRepeats() throws { try assertExportMatchesReference(name: "testMeasureRepeats") }
    @Test func initialKeySigThenRepeatToMeas2() throws {
        try assertExportMatchesReference(name: "testInitialKeySigThenRepeatToMeas2")
    }
    @Test func repeatsWithKeySigs() throws {
        try assertExportMatchesReference(name: "testRepeatsWithKeySigs")
    }
    @Test func repeatsWithKeySigsExceptFirstMeas() throws {
        try assertExportMatchesReference(name: "testRepeatsWithKeySigsExceptFirstMeas")
    }
    @Test func voltaTemp() throws { try assertExportMatchesReference(name: "testVoltaTemp") }
    @Test func voltaDynamic() throws { try assertExportMatchesReference(name: "testVoltaDynamic") }

    private func assertExportMatchesReference(name: String) throws {
        let scoreURL = try #require(Bundle.module.url(forResource: name, withExtension: "mscx"))
        let refURL = try #require(Bundle.module.url(forResource: "\(name)-ref", withExtension: "mid"))

        let score = try MuseScoreParser.loadScore(mscxData: try Data(contentsOf: scoreURL))
        let produced = try MuseScoreParser.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)

        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }
}
