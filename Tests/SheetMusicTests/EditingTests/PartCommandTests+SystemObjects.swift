@testable import SheetMusicCore
import Testing

/// What a part insertion and removal do to the top staff's system objects and to a removed part's own marks — the
/// cases MuseScore special-cases (`isTopSystemObject`), beside the structural ones in `PartCommandTests`.
extension PartCommandTests {
    /// A staff-bound mark keeps naming the staff it was written on; a score-wide mark on the top staff stays on top,
    /// as MuseScore keeps a top system object on track 0 when a staff goes in above it (`moveDownWhenAddingStaves`).
    @Test("an insertion re-stamps a staff-bound mark one part down and keeps a top-staff tempo on top")
    func addPartRestampsSystemElementAddresses() throws {
        var score = try fixture()
        score.systemMeasures.updateValue(at: 1) { column in
            let pairs = column.elements.indices.map { (column.elements.eid(at: $0), column.elements[$0]) }
            column.elements = IdentifiedArray(pairs + [(.invalid, PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: "pizz.")), originalStaff: Score.canonicalStaff,
            ))])
        }
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 0)))
        // `Score.blank`'s opening tempo is written on (0, 0) by name.
        #expect(session.score.systemMeasures[0].elements.first?.originalStaff == Score.canonicalStaff)
        let pizz = try #require(session.score.systemMeasures[1].elements.first?.originalStaff)
        #expect(pizz == StaffAddress(partIndex: 1, staffIndexInPart: 0))
        #expect(session.score.staffDisplayName(at: pizz) == "Flute")
    }

    /// An insertion at the top makes the new part the top staff, so the score's measure flags and its voltas move onto
    /// it, as a removal of the first part moves them off. Undo restores the old top staff exactly; redo the new one.
    @Test("an insertion at the top moves the measure flags and voltas onto the new part, exactly undone and redone")
    func addPartAtTheTopHoistsTheTopStaffsSystemObjects() throws {
        var score = try fixture()
        let ref = MeasureRef(measureIndex: 2)
        var bar = try #require(score[measure: ref, staff: Score.canonicalStaff])
        bar.startRepeat = true
        let existing = bar.voices[0].elements
        let volta = VoiceElement.spanner(
            Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [1]),
        )
        bar.voices[0].elements = IdentifiedArray(
            existing.indices.map { (existing.eid(at: $0), existing[$0]) } + [(EID.invalid, volta)],
        )
        score[measure: ref, staff: Score.canonicalStaff] = bar
        let original = score
        var ids = EIDAllocator()

        let inverse = try AddPart(plan: Self.clarinet, at: 0).apply(to: &score, ids: &ids)
        let added = score

        let top = try #require(score[measure: ref, staff: Score.canonicalStaff])
        #expect(top.startRepeat)
        #expect(top.voices[0].elements.first == volta)
        let flute = try #require(score[measure: ref, staff: StaffAddress(partIndex: 1, staffIndexInPart: 0)])
        #expect(!flute.startRepeat)
        #expect(!flute.voices.contains { $0.elements.contains(volta) })

        let redo = try inverse.apply(to: &score, ids: &ids)
        #expect(score == original)
        _ = try redo.apply(to: &score, ids: &ids)
        #expect(score == added)
    }

    /// MuseScore writes a linked copy of the top staff's tempo on each system-object staff; removing that staff takes
    /// the copy with it. Re-anchored on the top staff instead, it doubled the tempo printed there.
    @Test("a removed part's copy of a top-staff mark goes with it rather than doubling the mark on top")
    func removePartDropsACopyOfATopStaffMark() throws {
        var score = try fixture()
        let tempo = try #require(score.systemMeasures[0].elements.first)
        score.systemMeasures.updateValue(at: 0) { column in
            let pairs = column.elements.indices.map { (column.elements.eid(at: $0), column.elements[$0]) }
            var copy = tempo
            copy.originalStaff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
            column.elements = IdentifiedArray(pairs + [(.invalid, copy)])
        }
        let original = score
        let inverse = try RemovePart(partIndex: 1).apply(to: &score)
        #expect(score.systemMeasures[0].elements.values == [tempo])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A staff-bound mark belongs to its staff's music, as MuseScore deletes a removed staff's annotations. It used to
    /// re-anchor on the first staff like a tempo: a `pizz.` then printed over the flute, and an instrument change —
    /// which every consumer keys on its part — switched the flute's sound.
    @Test("a staff-bound system element of the removed part goes with it, and comes back on undo")
    func removePartDropsItsStaffBoundSystemElements() throws {
        var score = try fixture()
        let pianoLower = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        score.systemMeasures.updateValue(at: 1) { column in
            let pairs = column.elements.indices.map { (column.elements.eid(at: $0), column.elements[$0]) }
            column.elements = IdentifiedArray(pairs + [
                (.invalid, PositionedSystemElement(
                    position: .start, element: .staffText(StaffText(text: "pizz.")), originalStaff: pianoLower,
                )),
                (.invalid, PositionedSystemElement(
                    position: .start,
                    element: .instrumentChange(InstrumentChange(text: "to Harpsichord", instrument: Instrument(
                        id: "harpsichord",
                    ))),
                    originalStaff: pianoLower,
                )),
                (.invalid, PositionedSystemElement(
                    position: .start, element: .tempo(Tempo(beatsPerSecond: 3)), originalStaff: pianoLower,
                )),
            ])
        }
        let original = score
        let inverse = try RemovePart(partIndex: 1).apply(to: &score)
        let kept = score.systemMeasures[1].elements.values
        #expect(kept.count == 1)
        guard case .tempo = kept.first?.element else {
            Issue.record("expected the tempo alone to survive, got \(kept)"); return
        }
        #expect(kept.first?.originalStaff == Score.canonicalStaff)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// The first part's voltas and gradual tempo changes are the score's, not the instrument's: MuseScore keeps a top
    /// system object on track 0. Removed with the part, the score lost its repeat endings and its rit. lines.
    @Test("removing the first part moves its voltas and gradual tempo changes onto the new first staff")
    func removeFirstPartHoistsSystemSpanners() throws {
        var score = try fixture()
        let ref = MeasureRef(measureIndex: 2)
        var bar = try #require(score[measure: ref, staff: Score.canonicalStaff])
        let existing = bar.voices[0].elements
        let volta = VoiceElement.spanner(
            Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [1]),
        )
        bar.voices[0].elements = IdentifiedArray(
            [(EID.invalid, volta)] + existing.indices.map { (existing.eid(at: $0), existing[$0]) },
        )
        score[measure: ref, staff: Score.canonicalStaff] = bar
        let original = score
        let inverse = try RemovePart(partIndex: 0).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["piano"])
        let head = try #require(score[measure: ref, staff: Score.canonicalStaff]).voices[0].elements
        #expect(head.first == volta)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }
}
