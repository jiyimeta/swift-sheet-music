import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// Holds the `.museScore` preset to MuseScore's own "regroup rhythms" test data. That data is GPL and is never
/// copied here: the test reads it from the directory named by `SM_MUSESCORE_REGROUP_DATA` at run time, and without
/// the variable it does not run.
///
/// Point it at the data as of MuseScore commit `5de7c22880^` (`git archive 5de7c22880^
/// src/engraving/tests/rhythmicGrouping_data`). From `5de7c22880` on, the `-ref` files are written in the 5.00 format,
/// whose `<Tie>` inside `<Note>` ssm does not decode yet, so every tie in a reference reads as absent and the gate
/// reports mismatches that are the decoder's, not the formatter's.
@Suite("FormatRhythms MuseScore corpus")
struct FormatRhythmsMuseScoreCorpusTests {
    static let dataDirectory = ProcessInfo.processInfo.environment["SM_MUSESCORE_REGROUP_DATA"]

    /// `groupArticulationsTies` is out: folino deliberately does not delete the markings MuseScore removes there.
    /// `groupConflicts` is compared on staff 1 only, as the Python checker does.
    static let names = [
        "group8ths4-4", "group8thsCompound", "group8thsSimple", "groupConflicts", "groupShortenNotes",
        "groupSubbeats", "groupVoices",
    ]

    @Test(
        "the museScore preset reproduces MuseScore's references",
        .enabled(if: dataDirectory != nil),
    )
    func matchesReferences() throws {
        let directory = try URL(fileURLWithPath: #require(Self.dataDirectory), isDirectory: true)
        var compared = 0
        var mismatched = 0
        var report: [String] = []
        for name in Self.names {
            // Two deliberate walls in folino's formatter, neither a splitter fault (design §4.1, §4.2): a preserved
            // `<Beam>` marker between two chords stops a tie merge, and a chord carrying an articulation is left as
            // written. MuseScore's fixtures carry both, so the gate strips them from its input (the articulations in
            // `groupShortenNotes` only, where they are the point of the fixture) and measures the splitter and the
            // span rules; the unstripped result is recorded in the task report.
            var input = try FormatRhythmsGate.withoutBeamMarkers(
                MSCXParser.parse(contentsOf: directory.appendingPathComponent("\(name).mscx")),
            )
            if name == "groupShortenNotes" { input = FormatRhythmsGate.withoutArticulationsAndFermatas(input) }
            let reference = try MSCXParser.parse(contentsOf: directory.appendingPathComponent("\(name)-ref.mscx"))
            let formatted = try FormatRhythmsGate.applied(input, policy: .museScore).score
            let staffLimit = name == "groupConflicts" ? 1 : Int.max
            var fileCompared = 0
            var fileMismatched = 0
            for (staffIndex, entry) in formatted.allStaves.enumerated() where staffIndex < staffLimit {
                let original = input.allStaves[staffIndex].staff
                let expected = reference.allStaves[staffIndex].staff
                for (measureIndex, measure) in entry.staff.measures.enumerated() {
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        let before = FormatRhythmsGate.tokens(of: original.measures[measureIndex].voices[voiceIndex])
                        guard !before.isEmpty, expected.measures[measureIndex].voices.indices.contains(voiceIndex)
                        else { continue }
                        fileCompared += 1
                        let got = FormatRhythmsGate.tokens(of: voice)
                        let want = FormatRhythmsGate.tokens(of: expected.measures[measureIndex].voices[voiceIndex])
                        if got != want {
                            fileMismatched += 1
                            report.append(
                                "\(name) s\(staffIndex + 1) m\(measureIndex + 1) v\(voiceIndex + 1): "
                                    + "in \(before.joined(separator: " ")) | ref \(want.joined(separator: " ")) | "
                                    + "got \(got.joined(separator: " "))",
                            )
                        }
                    }
                }
            }
            // A fixture that compares nothing has stopped being read (a format change, a renamed staff), not passed.
            #expect(fileCompared > 0, "\(name): no voice-measure compared")
            compared += fileCompared
            mismatched += fileMismatched
            Issue.record(
                Comment(rawValue: "\(name): \(fileCompared) voice-measures compared, \(fileMismatched) mismatches"),
                severity: .warning,
            )
        }
        // 206 voice-measures when the floor was set (2026-10-18, MuseScore's data at the parent of 5de7c22880, the
        // last commit before its references moved to the 5.00 format that writes a tie as `<Tie>` inside `<Note>`).
        #expect(compared >= 200, "voice-measures compared: \(compared)")
        for line in report {
            Issue.record(Comment(rawValue: line))
        }
        #expect(mismatched == 0)
    }
}
