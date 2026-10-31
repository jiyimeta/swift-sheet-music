@testable import SheetMusicCore
import Testing

/// Existing editing commands that touch grace notes keep working on a grace that begins a slur, and keep the slur.
@Suite("Grace-note slurs under editing")
struct GraceSlurEditingTests {
    private typealias F = GraceIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    private static let slur = Spanner(kind: .slur, rawType: "Slur")

    private static func slurredGrace(_ pitch: Int = 59) -> GraceChord {
        var grace = F.grace(pitch)
        grace.spanners = [slur]
        return grace
    }

    /// A host restating the chord's graces from what it shows — the wire form carries no slurs — while adding one
    /// must not take the slur off the grace that already had it.
    @Test("adding a grace next to a slurred one keeps the slur, and undo restores the slot exactly")
    func addingAGraceKeepsTheSlur() throws {
        let slurred = Self.slurredGrace()
        let editor = ScoreEditor(score: F.score(before: [slurred], after: []))
        let before = editor.score
        let old = try F.chord(before)
        var restated = slurred
        restated.spanners = []
        try editor.apply(SetGraceNotes(at: V.location(0), before: [restated, F.grace(62)], after: []))
        let result = try F.chord(editor.score)
        #expect(result.graceNotesBefore.count == 2)
        #expect(result.graceNotesBefore[0].spanners == [Self.slur])
        #expect(result.graceNotesBefore.eid(at: 0) == old.graceNotesBefore.eid(at: 0))
        #expect(result.graceNotesBefore[1].spanners.isEmpty)
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test("removing the slurred grace removes its slur, and undo brings both back")
    func removingTheGraceTakesItsSlur() throws {
        let editor = ScoreEditor(score: F.score(before: [Self.slurredGrace()], after: []))
        let before = editor.score
        try editor.apply(SetGraceNotes(at: V.location(0), before: [], after: []))
        #expect(try F.chord(editor.score).graceNotesBefore.isEmpty)
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
        try editor.undo()
        #expect(try F.chord(editor.score).graceNotesBefore.first?.spanners == [Self.slur])
    }

    @Test("transposing the score keeps a grace's slur")
    func transposeKeepsTheSlur() throws {
        let editor = ScoreEditor(score: F.score(before: [Self.slurredGrace()], after: []))
        let before = editor.score
        try editor.apply(TransposeScore(semitones: 2, transposeKeySignatures: false))
        let grace = try #require(F.chord(editor.score).graceNotesBefore.first)
        #expect(grace.notes.first?.pitch == 61)
        #expect(grace.spanners == [Self.slur])
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    /// The common grace slur has no offset at all, so inserting a bar ahead of it moves nothing it depends on.
    @Test("inserting a measure ahead of a grace slurred into its principal leaves it intact")
    func insertMeasureKeepsTheSlur() throws {
        let editor = ScoreEditor(score: F.score(before: [Self.slurredGrace()], after: []))
        let before = editor.score
        try editor.apply(InsertMeasure(measureIndex: 0))
        let moved = editor.score.parts[0].staves[0].measures[1].voices[0].elements
        let chord: Chord? = moved.values.lazy.compactMap { element -> Chord? in
            guard case let .chord(chord) = element, !chord.notes.isEmpty else { return nil }
            return chord
        }.first
        #expect(chord?.graceNotesBefore.first?.spanners == [Self.slur])
        try TupletIdentityFixtures.expectRoundTrip(editor, before: before, after: editor.score)
    }

    /// A duplicated bar carries its graces whole. A slur into the grace's own principal note needs no re-anchoring and
    /// travels; one reaching another chord would arrive with the source's offsets, so it is left behind — the way a
    /// chord's slur that cannot be re-anchored is.
    @Test("duplicating a bar keeps a grace slurred into its principal and drops one that leaves the run")
    func duplicateRangeKeepsRunSlurs() throws {
        var leaving = Self.slur
        leaving.nextFractionsOffset = Fraction(numerator: 1, denominator: 4)
        var leavingGrace = F.grace(64)
        leavingGrace.spanners = [leaving]
        let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var score = Score(division: 480, parts: [Part(
            id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
            staves: [Staff(defaultClefType: "G", measures: [
                Measure(voices: [Voice(elements: [
                    .chord(Chord(
                        duration: .quarter,
                        notes: [Note(pitch: 60, tpc: 14)],
                        graceNotesBefore: [Self.slurredGrace()],
                    )),
                    .chord(Chord(
                        duration: .quarter,
                        notes: [Note(pitch: 62, tpc: 16)],
                        graceNotesBefore: [leavingGrace],
                    )),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 19)])),
                ])]),
                Measure(voices: [Voice(elements: [
                    .rest(duration: .quarter), .rest(duration: .quarter),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ])]),
            ])],
        )])
        let slot = { (element: Int) in
            VoiceElementID(staff: flute, measureIndex: 0, voiceIndex: 0, elementIndex: element)
        }
        _ = try DuplicateRange(over: VoiceElementRange(start: slot(0), end: slot(3))).apply(to: &score)
        func graceSpanners(_ measure: Int, _ element: Int) -> [Spanner]? {
            guard case let .chord(chord) = score.parts[0].staves[0].measures[measure].voices[0].elements[element]
            else { return nil }
            return chord.graceNotesBefore.first?.spanners
        }
        #expect(graceSpanners(1, 0) == [Self.slur])
        #expect(graceSpanners(1, 1) == [])
        // The source keeps both.
        #expect(graceSpanners(0, 0) == [Self.slur])
        #expect(graceSpanners(0, 1) == [leaving])
    }

    /// The fingerprint a host mirror is checked against sees a grace's slur, by occupants: a score without one hashes
    /// as it always did.
    @Test("the score fingerprint tells a slurred grace from a plain one")
    func fingerprintSeesTheSlur() {
        let plain = F.score(before: [F.grace()], after: [])
        let slurred = F.score(before: [Self.slurredGrace()], after: [])
        #expect(plain.stableFingerprint != slurred.stableFingerprint)
        var endingOnGrace = Self.slur
        endingOnGrace.nextGraceIndex = 0
        var gracedEnd = F.score(before: [F.grace()], after: [])
        F.mutate(&gracedEnd) { $0.spanners = [endingOnGrace] }
        var chordEnd = F.score(before: [F.grace()], after: [])
        F.mutate(&chordEnd) { $0.spanners = [Self.slur] }
        #expect(gracedEnd.stableFingerprint != chordEnd.stableFingerprint)
    }
}
