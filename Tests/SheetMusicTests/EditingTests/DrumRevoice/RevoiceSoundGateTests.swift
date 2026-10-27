import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// What the corpus gate looked at, so a green run can be told from an empty one.
struct RevoiceSoundGateCounts {
    var scores = 0
    var skipped = 0
    var staves = 0
    var rewrittenBars = 0
    var barsLeft = 0
    var conversions = 0
}

/// The sound gate (design 2026-10-26, drum voice conversion, §5) run over the fixture corpus: every percussion staff
/// converts to hands and feet and back to one voice without changing what plays or where a marking sits, and one voice
/// is a fixed point. The synthetic cases beside it are the ones the corpus may not hold.
@Suite("RevoiceDrumStaff sound gate")
struct RevoiceSoundGateTests {
    /// The pad's hands-and-feet split read from the GM kit: every drum the kit engraves in voice 2 (index 1).
    private static let kitHandsAndFeet: [Int: Int] = GMDrumset.entries.compactMapValues { entry in
        entry.voiceIndex == 0 ? nil : entry.voiceIndex
    }

    /// Plans and applies `RevoiceDrumStaff` over `staff` in place, with the allocator the whole chain shares. Nil when
    /// the command would change nothing.
    private static func convert(
        _ score: inout Score, ids: inout EIDAllocator, staff: StaffAddress, to map: [Int: Int],
    ) throws -> CompositeEditCommand? {
        let command = RevoiceDrumStaff(staff: staff, voiceForPitch: map, policy: .default)
        guard let plan = try command.plan(in: score, ids: ids) else { return nil }
        _ = try plan.apply(to: &score, ids: &ids)
        return plan
    }

    private static func preview(_ score: Score, staff: StaffAddress, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    @Test func `every percussion staff in the fixtures converts both ways without changing its sound`() throws {
        var counts = RevoiceSoundGateCounts()
        for url in FormatRhythmsInvariantTests.topLevelFixtures() {
            guard let parsed = try? MSCXParser.parse(contentsOf: url), (try? MidiRenderer.render(score: parsed)) != nil
            else {
                counts.skipped += 1
                continue
            }
            counts.scores += 1
            let drumStaves = parsed.allStaves.filter { parsed.parts[$0.address.partIndex].instrument.useDrumset }
            for (address, _) in drumStaves {
                counts.staves += 1
                var score = parsed
                var ids = EIDAllocator()
                score.assignMissingIDs(using: &ids)
                let name = "\(url.lastPathComponent) staff \(address)"

                // One voice or hands and feet, whichever the staff is not in, then back: the two directions are two
                // mappings, so both run on every staff. Each step is judged against the step before it.
                for map in [Self.kitHandsAndFeet, RevoiceFixtures.oneVoice] {
                    let before = score
                    let preview = Self.preview(before, staff: address, to: map)
                    counts.rewrittenBars += preview.rewrittenMeasures.count
                    counts.barsLeft += preview.measuresLeftAsWritten.count
                    counts.conversions += 1
                    _ = try Self.convert(&score, ids: &ids, staff: address, to: map)
                    try RevoiceSoundGate.expectKeepsSound(before: before, after: score, staff: address)
                }
                // The staff is in one voice now, as far as it can be: converting again changes nothing.
                let again = try Self.convert(&score, ids: &ids, staff: address, to: RevoiceFixtures.oneVoice)
                #expect(again == nil, "one voice is a fixed point: \(name)")
            }
        }
        Issue.record(Comment(rawValue: "gate coverage: \(counts)"), severity: .warning)
        // Floors come after the first measured run (task A6, step 3): without them an emptied gate would stay green.
        #expect(counts.skipped == 0, "fixtures skipped: \(counts.skipped)")
    }

    // MARK: Synthetic cases

    /// A kick tied from bar 0 into bar 1, where bar 1 holds a rolled snare beside the kick's partner and so is left as
    /// written (a kick merged onto a rolled snare, §4.5). Bar 0's kick moves from voice 2 into voice 1; its partner
    /// stays in bar 1's voice 2. The two pair by position (`CrossVoiceTies`), so it still sounds as one note.
    @Test func `a tie into a bar left as written still sounds as one note`() throws {
        var score = RevoiceFixtures.score([
            ["S/4 S/4 S/4 r/4", "r/2. K/4~"],
            ["S/4 H/4 H/4 H/4", "~K/4 r/4 r/2"],
        ])
        score = RevoiceFixtures.editingChord(score, measure: 1, voice: 0, element: 0) { chord in
            chord.tremolo = Tremolo(subtype: .r16, span: .single)
        }
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1]))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 1)
        #expect(RevoiceFixtures.voices(after, measure: 1).count == 2)
        #expect(FormatRhythmsGate.danglingTies(in: after) == FormatRhythmsGate.danglingTies(in: score))
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    /// The same tie the other way: the kick starts in voice 0 of bar 0 and moves to voice 1 under hands and feet, while
    /// its partner at the head of bar 1 stays in voice 0 because the glissando on the tom after it leaves that bar.
    @Test func `a tie into a bar left as written still sounds as one note when a kick moves to voice two`() throws {
        var score = RevoiceFixtures.score([
            ["S/4 S/4 S/4 K/4~"],
            ["~K/4 T/4 T/4 H/4"],
        ])
        score = RevoiceFixtures.editingChord(score, measure: 1, voice: 0, element: 1) { chord in
            chord.notes.updateNote(at: 0) { $0.glissando = Glissando() }
        }
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.handsAndFeet)
            == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1]))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 2)
        #expect(FormatRhythmsGate.danglingTies(in: after) == FormatRhythmsGate.danglingTies(in: score))
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    /// A bar whose voice 0 is a single measure rest and whose kicks sit in voice 1 converts to one voice: the rest
    /// gives way to the kicks rather than leaving the bar as written.
    @Test func `a measure rest in the first voice gives way to the kicks of the second`() throws {
        let score = RevoiceFixtures.score([["r/m", "K/4 r/4 K/4 r/4"], ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"]])
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [0, 1], measuresLeftAsWritten: []))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 1)
        #expect(RevoiceFixtures.voices(after, measure: 1).count == 1)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    // An underfull first voice next to normal bars is `RevoiceBarLengthTests`' `an underfull first voice leaves its
    // bar`, which already runs the sound gate over it; no second case here.
}
