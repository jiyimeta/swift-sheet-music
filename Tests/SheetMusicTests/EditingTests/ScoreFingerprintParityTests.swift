import Foundation
@testable import SheetMusicCore
import Testing

@Suite("Score fingerprint — parity fields")
struct ScoreFingerprintParityTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let slot = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

    /// The committed standard chain's first fingerprint — `editReplay/goldens.txt` line 1 — computed from the
    /// in-memory fixture. Pins "a score with none of the new fields set hashes exactly as before" directly, so
    /// the by-occupants rule is checked here and not only through the golden suites.
    @Test("a score with every new field at its default hashes exactly as it did before this change")
    func defaultsHashUnchanged() throws {
        let goldens = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Android/SheetMusicAndroid/src/androidTest/assets/editReplay/goldens.txt")
        let first = try String(contentsOf: goldens, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).first.flatMap { Int64($0) }
        #expect(EditingFixtures.replayFixture().stableFingerprint == first)
    }

    /// `WritableKeyPath` is a class and does not conform to `Sendable`, which `@Test(arguments:)` requires of its
    /// elements — this wrapper carries the keypath across that boundary; it is safe because a keypath is
    /// immutable value-identity, never mutated after construction.
    private struct MeasureFlagKeyPath: @unchecked Sendable {
        let path: WritableKeyPath<Measure, Bool>
    }

    @Test("each measure flag moves the fingerprint, and clearing it moves it back", arguments: [
        MeasureFlagKeyPath(path: \Measure.lineBreak),
        MeasureFlagKeyPath(path: \Measure.pageBreak),
        MeasureFlagKeyPath(path: \Measure.sectionBreak),
        MeasureFlagKeyPath(path: \Measure.startRepeat),
    ])
    private func boolFlagsAreCovered(flag: MeasureFlagKeyPath) {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        score.parts[0].staves[0].measures[0][keyPath: flag.path] = true
        #expect(score.stableFingerprint != before)
        score.parts[0].staves[0].measures[0][keyPath: flag.path] = false
        #expect(score.stableFingerprint == before)
    }

    @Test("repeat counts, markers and jumps are covered and distinguishable")
    func countsMarkersJumps() {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        score.parts[0].staves[0].measures[0].endRepeatCount = 2
        let endRepeat = score.stableFingerprint
        #expect(endRepeat != before)
        score.parts[0].staves[0].measures[0].endRepeatCount = nil
        score.parts[0].staves[0].measures[0].measureRepeatCount = 2
        #expect(score.stableFingerprint != endRepeat, "same value under a different tag must differ")
        score.parts[0].staves[0].measures[0].measureRepeatCount = nil
        score.parts[0].staves[0].measures[0].markers = [Marker(kind: .coda, label: "codab")]
        let coda = score.stableFingerprint
        score.parts[0].staves[0].measures[0].markers = [Marker(kind: .segno, label: "segno")]
        #expect(score.stableFingerprint != coda)
        score.parts[0].staves[0].measures[0].markers = []
        score.parts[0].staves[0].measures[0].jumps = [
            Jump(jumpTo: "start", playUntil: "fine", continueAt: "", playRepeats: false, text: "D.C."),
        ]
        #expect(score.stableFingerprint != before)
        score.parts[0].staves[0].measures[0].jumps = []
        #expect(score.stableFingerprint == before)
    }

    @Test("a flag on measure 0 and the same flag on measure 1 hash differently")
    func flagsArePositional() {
        var a = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        var b = a
        a.parts[0].staves[0].measures[0].lineBreak = true
        b.parts[0].staves[0].measures[1].lineBreak = true
        #expect(a.stableFingerprint != b.stableFingerprint)
    }

    @Test("the marker VoiceElement cases now carry their content")
    func markerCasesCarryContent() {
        var score = EditingFixtures.fourQuarterRests()
        score[Self.slot] = .dynamic(Dynamic(subtype: "p", velocity: 49))
        let piano = score.stableFingerprint
        score[Self.slot] = .dynamic(Dynamic(subtype: "f", velocity: 96))
        #expect(score.stableFingerprint != piano)
        score[Self.slot] = .barLine(BarLine(subtype: "double"))
        let double = score.stableFingerprint
        score[Self.slot] = .barLine(BarLine(subtype: "end"))
        #expect(score.stableFingerprint != double)
        score[Self.slot] = .clef(Clef(concertClefType: "G"))
        let treble = score.stableFingerprint
        score[Self.slot] = .clef(Clef(concertClefType: "F"))
        #expect(score.stableFingerprint != treble)
    }

    @Test("chord and note element properties are covered by occupants")
    func elementPropertiesCovered() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        guard case var .chord(chord) = score[Self.slot] else { Issue.record("expected a chord"); return }
        chord.visible = false
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
        chord.visible = true
        chord.notes[0].elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
        chord.notes[0].elementProperties.color = nil
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint == before)
    }
}
