import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct MidiExportTests {
    @Test func midi01() throws {
        try assertExportMatchesReference(name: "midi01")
    }

    @Test func midi02() throws {
        try assertExportMatchesReference(name: "midi02")
    }

    @Test func midi03() throws {
        try assertExportMatchesReference(name: "midi03")
    }

    @Test func midiPortExport() throws {
        try assertExportMatchesReference(name: "testMidiPort")
    }

    @Test func midiArpeggio() throws {
        try assertExportMatchesReference(name: "testArpeggio")
    }

    @Test func midiMutedUnison() throws {
        try assertExportMatchesReference(name: "testMutedUnison")
    }

    @Test func midiMeasureRepeats() throws {
        try assertExportMatchesReference(name: "testMeasureRepeats")
    }

    @Test func initialKeySigThenRepeatToMeas2() throws {
        try assertExportMatchesReference(name: "testInitialKeySigThenRepeatToMeas2")
    }

    @Test func repeatsWithKeySigs() throws {
        try assertExportMatchesReference(name: "testRepeatsWithKeySigs")
    }

    @Test func repeatsWithKeySigsExceptFirstMeas() throws {
        try assertExportMatchesReference(name: "testRepeatsWithKeySigsExceptFirstMeas")
    }

    /// MuseScore's export carries ♩ = 180 across the jump into the second volta (tick 4320); the notation, MuseScore's
    /// playback and this SMF have the first volta's ♩ = 60 there until the second volta's own ♩ = 180, three eighths
    /// in (import-fidelity F2.10). Otherwise the reference is matched as it stands.
    @Test func voltaTemp() throws {
        try assertExportMatchesReference(
            name: "testVoltaTemp", restatedTempos: [(tick: 4320, microsecondsPerQuarter: 1_000_000)],
        )
    }

    @Test func voltaDynamic() throws {
        try assertExportMatchesReference(name: "testVoltaDynamic")
    }

    private func assertExportMatchesReference(
        name: String, restatedTempos: [(tick: Int, microsecondsPerQuarter: Int)] = [],
    ) throws {
        let scoreURL = try #require(TestResources.url(forResource: name, withExtension: "mscx"))
        let refURL = try #require(TestResources.url(forResource: "\(name)-ref", withExtension: "mid"))

        let score = try SheetMusic.loadScore(mscxData: Data(contentsOf: scoreURL))
        let produced = try Self.removing(restatedTempos, from: SheetMusic.exportMIDI(score: score))
        let reference = try Data(contentsOf: refURL)

        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }

    /// `smf` without the listed tempo metas of its first track — each of which it must carry.
    private static func removing(_ tempos: [(tick: Int, microsecondsPerQuarter: Int)], from smf: Data) throws -> Data {
        guard !tempos.isEmpty else { return smf }
        var file = try MidiReader.read(smf)
        for tempo in tempos {
            let index = file.tracks[0].events.firstIndex { event in
                guard case let .meta(.tempo(micros)) = event.event else { return false }
                return event.tick == tempo.tick && micros == tempo.microsecondsPerQuarter
            }
            let found = try #require(index, "no re-stated tempo \(tempo.microsecondsPerQuarter) at \(tempo.tick)")
            file.tracks[0].events.remove(at: found)
        }
        return try MidiWriter.write(file)
    }
}
