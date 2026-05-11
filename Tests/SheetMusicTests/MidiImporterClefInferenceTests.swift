import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("MidiImporter.inferClef")
struct MidiImporterClefInferenceTests {
    // MARK: - Algorithm

    @Test func emptyPitchesFallsBackToFirstCandidate() {
        #expect(MidiImporter.inferClef(pitches: [], candidates: [.treble, .bass]) == .treble)
        #expect(MidiImporter.inferClef(pitches: [], candidates: [.bass, .treble]) == .bass)
    }

    @Test func emptyCandidatesFallsBackToTreble() {
        #expect(MidiImporter.inferClef(pitches: [60], candidates: []) == .treble)
    }

    @Test func highRangeChoosesTreble() {
        // Right-hand piano line around C5..G5.
        let rh = [72, 74, 76, 77, 79]
        #expect(MidiImporter.inferClef(pitches: rh, candidates: [.treble, .bass]) == .treble)
    }

    @Test func lowRangeChoosesBass() {
        // Left-hand piano around C3..G3.
        let lh = [48, 50, 52, 53, 55]
        #expect(MidiImporter.inferClef(pitches: lh, candidates: [.treble, .bass]) == .bass)
    }

    @Test func tubaRangeProducesBass8vbWhenOctaveClefAllowed() {
        // Tuba written range hovers around E1..E2 (28..40). With
        // bass8vb in the candidate set we should prefer it over plain
        // bass.
        let tuba = [28, 31, 33, 36, 38, 40]
        #expect(
            MidiImporter.inferClef(
                pitches: tuba, candidates: [.treble, .bass, .bass8vb],
            ) == .bass8vb,
        )
    }

    @Test func tubaRangeFallsBackToBassIfOctaveClefDisallowed() {
        // Same pitches, but the app only offers treble/bass. We still
        // get the best of the two (bass), not a downstream surprise.
        let tuba = [28, 31, 33, 36, 38, 40]
        #expect(
            MidiImporter.inferClef(
                pitches: tuba, candidates: [.treble, .bass],
            ) == .bass,
        )
    }

    @Test func cClefAppOnlyHasCFamily() {
        // App scenario: viola-style — only C clefs allowed. A midrange
        // line near C4 should resolve to alto.
        let viola = [55, 57, 60, 62, 64, 67] // G3..G4
        #expect(
            MidiImporter.inferClef(
                pitches: viola, candidates: [.soprano, .alto, .tenor, .baritone],
            ) == .alto,
        )
    }

    @Test func tieBreaksToEarlierCandidate() {
        // pitches [71, 50] are symmetric: B4 sits on treble's mid-
        // line (cost 0) and D3 21 semitones below; bass has it
        // reversed. Total cost identical → earlier wins.
        let mirrored = [71, 50]
        #expect(
            MidiImporter.inferClef(
                pitches: mirrored, candidates: [.treble, .bass],
            ) == .treble,
        )
        #expect(
            MidiImporter.inferClef(
                pitches: mirrored, candidates: [.bass, .treble],
            ) == .bass,
        )
    }

    @Test func majorityWinsAgainstSingleOutlier() {
        // 99 high notes + 1 low note → still treble; sum-of-absolute
        // is dominated by the majority.
        var notes = Array(repeating: 79, count: 99) // G5
        notes.append(36) // single C2 outlier
        #expect(MidiImporter.inferClef(pitches: notes, candidates: [.treble, .bass]) == .treble)
    }

    // MARK: - Event extraction

    @Test func ignoresNoteOffAndZeroVelocityNoteOn() {
        // Some DAWs encode note-off as noteOn velocity 0. Those must
        // not pull the average pitch toward whatever the channel
        // happens to be.
        let events: [TimedMidiEvent] = [
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 79, velocity: 90)),
            TimedMidiEvent(tick: 240, event: .noteOn(channel: 0, pitch: 79, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 81, velocity: 90)),
            TimedMidiEvent(tick: 720, event: .noteOff(channel: 0, pitch: 81, velocity: 60)),
            TimedMidiEvent(tick: 960, event: .endOfTrack),
        ]
        #expect(
            MidiImporter.inferClef(events: events, candidates: [.treble, .bass]) == .treble,
        )
    }

    // MARK: - End-to-end integration

    @Test func importAssignsBassClefToLowTrack() throws {
        let division = 480
        let conductor = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let lowTrack = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("LowVoice"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 40, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 40, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 43, velocity: 80)),
            TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 43, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: division, format: 1, tracks: [conductor, lowTrack])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)
        let part = try #require(score.parts.first { $0.trackName == "LowVoice" })
        #expect(part.staves[0].defaultClefType == NotatedClef.bass.rawType)
    }

    @Test func importAssignsPercClefToDrumTrackRegardlessOfCandidates() throws {
        let division = 480
        let conductor = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let drums = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            // GM kick on channel 10 (zero-indexed 9).
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 90)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: division, format: 1, tracks: [conductor, drums])
        let bytes = try MidiWriter.write(file)
        // Even if the caller restricts candidates to C clefs only,
        // the drum staff must still come out as PERC.
        let opts = MidiImportOptions(clefCandidates: [.alto])
        let score = try MidiImporter.parse(bytes, options: opts)
        let drumPart = try #require(score.parts.first { $0.instrument.useDrumset })
        #expect(drumPart.staves[0].defaultClefType == NotatedClef.percussion.rawType)
    }

    @Test func candidateRestrictionFlowsThroughToImport() throws {
        // Caller restricts to [.treble] only — even an obviously-bass
        // line ends up on treble (with lots of ledger lines).
        let division = 480
        let conductor = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let low = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Cello"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 36, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: division, format: 1, tracks: [conductor, low])
        let bytes = try MidiWriter.write(file)
        let opts = MidiImportOptions(clefCandidates: [.treble])
        let score = try MidiImporter.parse(bytes, options: opts)
        let part = try #require(score.parts.first { $0.trackName == "Cello" })
        #expect(part.staves[0].defaultClefType == NotatedClef.treble.rawType)
    }
}
