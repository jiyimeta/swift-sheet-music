@testable import SheetMusicCore
import Testing

@Suite("CreateTuplet")
struct CreateTupletTests {
    private static let chordVE = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("triplet on a quarter chord produces 3 eighth-triplet members")
    func tripletOnQuarter() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // Original: [timeSig, chord(q), rest(q) × 3]. After:
        // [timeSig, chord(1/12), rest(1/12), rest(1/12), rest(q) × 3].
        #expect(voice.elements.count == 7)
        #expect(voice.tuplets.count == 1)
        let t = voice.tuplets[0]
        #expect(t.actualNotes == 3)
        #expect(t.normalNotes == 2)
        #expect(t.startIndex == 1)
        #expect(t.endIndex == 3)
        // First member retains the C4 chord; the other two are rests.
        guard case .chord(let c1) = voice.elements[1] else {
            Issue.record("first member should keep the chord"); return
        }
        #expect(!c1.notes.isEmpty)
        #expect(c1.notes.first?.pitch == 60)
        #expect(c1.duration == .fraction(Fraction(numerator: 1, denominator: 12)))
        guard case .chord(let r2) = voice.elements[2], r2.notes.isEmpty
        else { Issue.record("idx 2 should be a rest"); return }
        #expect(r2.duration == .fraction(Fraction(numerator: 1, denominator: 12)))
        guard case .chord(let r3) = voice.elements[3], r3.notes.isEmpty
        else { Issue.record("idx 3 should be a rest"); return }
        #expect(r3.duration == .fraction(Fraction(numerator: 1, denominator: 12)))
    }

    @Test("triplet on a quarter rest produces 3 rest members")
    func tripletOnRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        let cmd = CreateTuplet(
            at: restID, actualNotes: 3, normalNotes: 2)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.tuplets.count == 1)
        for j in 2...4 {
            guard case .chord(let r) = voice.elements[j], r.notes.isEmpty
            else { Issue.record("idx \(j) should be a rest"); return }
        }
    }

    @Test("quintuplet on a quarter chord produces 5 sixteenth-quintuplet members")
    func quintupletOnQuarter() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = CreateTuplet(
            at: Self.chordVE, actualNotes: 5, normalNotes: 4)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.tuplets[0].actualNotes == 5)
        #expect(voice.tuplets[0].endIndex - voice.tuplets[0].startIndex == 4)
        guard case .chord(let c) = voice.elements[1] else {
            Issue.record("expected chord"); return
        }
        // 480 / 5 = 96 ticks per member. As fraction-of-whole:
        // 96 / (4 * 480) = 1/20.
        #expect(c.duration == .fraction(Fraction(numerator: 1, denominator: 20)))
    }

    @Test("inverse round-trips a triplet creation")
    func inverseRoundTrip() throws {
        var score = EditingFixtures.chordAtIndex1()
        let snapshot = score
        let cmd = CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("refuses target inside an existing tuplet")
    func refusesNestedTuplet() {
        var score = EditingFixtures.chordAtIndex1()
        // First create a triplet.
        let outer = try? CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        _ = outer
        // Targeting a member of the new triplet should refuse.
        let memberVE = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2)
        let cmd = CreateTuplet(
            at: memberVE, actualNotes: 3, normalNotes: 2)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("refuses when ticks don't divide evenly")
    func refusesUnevenDivision() {
        var score = EditingFixtures.chordAtIndex1()
        // Quarter = 480 ticks; 480 / 7 isn't an integer.
        let cmd = CreateTuplet(
            at: Self.chordVE, actualNotes: 7, normalNotes: 4)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("tuplets after the target shift indices")
    func laterTupletShiftsIndices() throws {
        // Voice: [timeSig, q-chord, q-rest (target), q-rest, q-rest].
        // Pre-create a triplet on idx 1 (the chord) — gives a tuplet
        // at indices 1..3 — then create another triplet on the
        // q-rest that's now at idx 4 (originally idx 2). The
        // first tuplet's indices should not move.
        var score = EditingFixtures.chordAtIndex1()
        _ = try CreateTuplet(
            at: Self.chordVE, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        // After the first triplet voice is:
        //   [timeSig, m1, m2, m3, rest(q), rest(q), rest(q)]
        // Target the rest at idx 4.
        let secondTarget = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 4)
        _ = try CreateTuplet(
            at: secondTarget, actualNotes: 3, normalNotes: 2)
            .apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.tuplets.count == 2)
        let first = voice.tuplets[0]
        let second = voice.tuplets[1]
        #expect(first.startIndex == 1 && first.endIndex == 3)
        #expect(second.startIndex == 4 && second.endIndex == 6)
    }
}
