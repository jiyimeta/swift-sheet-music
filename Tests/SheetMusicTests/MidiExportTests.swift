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

    /// MuseScore's export starts each return to bar 1 at mf; MuseScore 4's playback and this SMF carry in the p the
    /// first and second endings close on, up to bar 1's own fff three eighths in (import-fidelity W4, owner decision
    /// c). Otherwise the reference is matched as it stands.
    @Test func voltaDynamic() throws {
        let carriedPiano = [2880, 3120, 3360, 5760, 6000, 6240].map { (tick: $0, velocity: 49) }
        try assertExportMatchesReference(name: "testVoltaDynamic", playbackVelocities: carriedPiano)
    }

    private func assertExportMatchesReference(
        name: String, restatedTempos: [(tick: Int, microsecondsPerQuarter: Int)] = [],
        playbackVelocities: [(tick: Int, velocity: Int)] = [],
    ) throws {
        let scoreURL = try #require(TestResources.url(forResource: name, withExtension: "mscx"))
        let refURL = try #require(TestResources.url(forResource: "\(name)-ref", withExtension: "mid"))

        let score = try SheetMusic.loadScore(mscxData: Data(contentsOf: scoreURL))
        let produced = try Self.removing(restatedTempos, from: SheetMusic.exportMIDI(score: score))
        let reference = try Self.replacing(playbackVelocities, in: Data(contentsOf: refURL))

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

    /// `smf` with every note-on at each listed tick sounding at the listed velocity — what MuseScore 4's playback plays
    /// there where its export does not.
    private static func replacing(_ velocities: [(tick: Int, velocity: Int)], in smf: Data) throws -> Data {
        guard !velocities.isEmpty else { return smf }
        var file = try MidiReader.read(smf)
        for (tick, velocity) in velocities {
            var found = false
            for track in file.tracks.indices {
                for index in file.tracks[track].events.indices where file.tracks[track].events[index].tick == tick {
                    guard case let .noteOn(channel, pitch, old) = file.tracks[track].events[index].event, old > 0 else {
                        continue
                    }
                    file.tracks[track].events[index].event = .noteOn(channel: channel, pitch: pitch, velocity: velocity)
                    found = true
                }
            }
            #expect(found, "no note-on at \(tick) in the reference")
        }
        return try MidiWriter.write(file)
    }
}
