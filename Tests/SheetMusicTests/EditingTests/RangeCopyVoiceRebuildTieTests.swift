@testable import SheetMusicCore
import Testing

/// Covers the tie clearing `RangeCopyVoiceRebuild.cut` applies when the replaced span's boundary falls exactly
/// on an element boundary — so neither `leadingTrim` nor `trailingTrim` runs, and the surviving neighbour is
/// filed into `before`/`after` untouched unless this pass catches it. Split from `RangeCopyVoiceRebuildTests`
/// to keep that file under the project's 400-line budget.
@Suite("RangeCopyVoiceRebuild ties at an element-aligned boundary")
struct RangeCopyVoiceRebuildTieTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func quarter(_ pitch: Int, tieForward: Int? = nil, tieBack: Int? = nil) -> VoiceElement {
        var note = Note(pitch: pitch, tpc: 14)
        note.tieForward = tieForward
        note.tieBack = tieBack
        return .chord(Chord(duration: .quarter, notes: [note]))
    }

    private static func piece(start: Int, elements: [VoiceElement]) -> RangeCopyPlacement.Piece {
        RangeCopyPlacement.Piece(measureIndex: 0, startTickInMeasure: start, elements: elements, tuplets: [])
    }

    private static func voice(_ score: Score) -> Voice {
        score.parts[0].staves[0].measures[0].voices[0]
    }

    /// One 4/4 bar of four quarters, `elements[left]` tied forward into `elements[left + 1]`. Every other
    /// tie field is left `nil`, so only the pair under test carries one.
    private static func fourQuartersTied(from left: Int) -> Score {
        var elements: [VoiceElement] = (0 ..< 4).map { Self.quarter(60 + $0) }
        elements[left] = Self.quarter(60 + left, tieForward: 1)
        elements[left + 1] = Self.quarter(60 + left + 1, tieBack: 1)
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [Voice(elements: elements)])])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        return score
    }

    @Test("a chord just before an element-aligned span loses the tie that pointed into the copy")
    func clearsTieForwardAtAlignedLeadingBoundary() throws {
        var score = Self.fourQuartersTied(from: 0)
        // [480, 1920) is beats 2-4 exactly: element-aligned at both ends, so `leadingTrim` never runs and the
        // first quarter is filed into `before` as-is unless the cut itself clears its tie.
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(start: 480, elements: [Self.quarter(70), Self.quarter(71), Self.quarter(72)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score).elements
        guard case let .chord(first) = elements[0] else {
            Issue.record("expected the untouched leading quarter to survive as a chord")
            return
        }
        #expect(first.notes[0].tieForward == nil)
    }

    @Test("a chord just after an element-aligned span loses the tie that pointed into the overwritten material")
    func clearsTieBackAtAlignedTrailingBoundary() throws {
        var score = Self.fourQuartersTied(from: 1)
        // [0, 960) is beats 1-2 exactly: element-aligned at both ends, so `trailingTrim` never runs and the
        // third quarter (index 2, tied back to the second) is filed into `after` as-is unless the cut clears it.
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(start: 0, elements: [Self.quarter(70), Self.quarter(71)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score).elements
        #expect(elements.count == 4)
        guard elements.count == 4, case let .chord(third) = elements[2] else {
            Issue.record("expected the untouched trailing quarter to survive as a chord")
            return
        }
        #expect(third.notes[0].tieBack == nil)
    }
}
