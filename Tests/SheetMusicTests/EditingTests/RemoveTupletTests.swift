@testable import SheetMusicCore
import Testing

@Suite("RemoveTuplet")
struct RemoveTupletTests {
    private static let chordVE = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("removes a triplet, restoring a single chord of the total span")
    func removesTriplet() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        // Remove the triplet by targeting any member.
        let memberID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        _ = try RemoveTuplet(at: memberID).apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // Original 4-quarter measure restored: [timeSig, chord(q),
        // rest(q), rest(q), rest(q)].
        #expect(voice.tuplets.isEmpty)
        #expect(voice.elements.count == 5)
        guard case .chord(let c) = voice.elements[1] else {
            Issue.record("expected chord at idx 1"); return
        }
        #expect(c.notes.first?.pitch == 60)
        // Quarter == 480 ticks == 1/4 of whole.
        #expect(c.duration.ticks(division: 480) == 480)
    }

    @Test("removes a rest-only triplet, restoring a single rest")
    func removesRestTriplet() throws {
        var score = EditingFixtures.fourQuarterRests()
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        _ = try CreateTuplet(
            at: restID, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        let memberID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 3)
        _ = try RemoveTuplet(at: memberID).apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.tuplets.isEmpty)
        #expect(voice.elements.count == 5)
        guard case .chord(let r) = voice.elements[2], r.notes.isEmpty
        else { Issue.record("expected rest at idx 2"); return }
        #expect(r.duration.ticks(division: 480) == 480)
    }

    @Test("inverse round-trips a tuplet removal")
    func inverseRoundTrip() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        let snapshot = score
        let memberID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        let cmd = RemoveTuplet(at: memberID)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("refuses when target isn't inside any tuplet")
    func refusesOnNonTupletTarget() {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = RemoveTuplet(at: Self.chordVE)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
