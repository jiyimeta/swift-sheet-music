@testable import SheetMusicCore
import Testing

/// `.setKeySignature` / `.removeKeySignature` — the two signature intents, driven through `ScoreEditSession` so the
/// span re-spelling the planner bundles with them is part of what every assertion sees.
@Suite("Key signature intents")
struct SetKeySignatureTests {
    /// Piano + B♭ clarinet + drum kit, 4 bars, G major (1 sharp), an F♯ chord in every bar of the pitched parts,
    /// and an existing explicit key change to D (2 sharps) at bar 2.
    private func fixture() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")]),
                .init(
                    instrumentID: "clarinet-bb", longName: "Clarinet",
                    staves: [.init(clefType: "G")], transposeDiatonic: -1, transposeChromatic: -2,
                ),
                .init(
                    instrumentID: "drumset", longName: "Drums",
                    staves: [.init(clefType: "PERC", isPercussion: true)], isDrums: true,
                ),
            ],
            concertKey: 1, measureCount: 4,
        ))
        for part in [0, 1] {
            for measure in 0 ..< 4 {
                // Bar 0 opens on the key and time signature, so its measure rest sits at element 2; every later bar
                // holds the rest alone.
                let slot = measure == 0 ? 2 : 0
                score.parts[part].staves[0].measures[measure].voices[0].elements[slot] =
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 66, tpc: 20)]))
            }
            score.parts[part].staves[0].measures[2].voices[0].elements
                .insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
            MeasureStructure.shiftTuplets(in: &score.parts[part].staves[0].measures[2].voices[0], by: 1)
        }
        return score
    }

    private static let pianoStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private func hasKeySignature(_ score: Score, part: Int, measure: Int) -> Bool {
        score.parts[part].staves[0].measures[measure].voices[0].elements
            .contains(where: { if case .keySignature = $0 { true } else { false } })
    }

    /// The glyph on the fixture's chord in `measure`. Double-optional on purpose: the OUTER `nil` means the slot
    /// holds no chord at all, so `.some(nil)` — a chord carrying no glyph — stays distinguishable from a fixture
    /// that drifted out from under the test.
    private func accidental(_ score: Score, part: Int, measure: Int) -> Accidental?? {
        // Found rather than indexed: a bar's chord sits at element 2 in bar 0, at 1 in a bar that declares a key,
        // and at 0 elsewhere — and this suite's whole subject is elements moving in and out of that leading run.
        for element in score.parts[part].staves[0].measures[measure].voices[0].elements {
            if case let .chord(chord) = element { return chord.notes[0].accidental }
        }
        return nil
    }

    // MARK: - .setKeySignature

    @Test("the key lands on every pitched staff, skips percussion, and re-spells its own span")
    func setKeyWritesAllStavesSkipsPercussionAndRenotatesTheSpan() {
        let session = ScoreEditSession(score: fixture())
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: 0))) // G → C major
        let score = session.score
        for part in [0, 1] {
            guard case let .keySignature(key) = score.parts[part].staves[0].measures[0].voices[0].elements[0]
            else { Issue.record("expected a key signature at the head of bar 0"); return }
            #expect(key.concertKey == 0)
            // Bars 0 and 1 (the affected span) now show explicit ♯ glyphs; bar 2 onward is D major's span and must
            // be untouched.
            for measure in 0 ..< 2 {
                #expect(accidental(score, part: part, measure: measure) == .some(.sharp))
            }
            #expect(accidental(score, part: part, measure: 2) == .some(nil))
            #expect(accidental(score, part: part, measure: 3) == .some(nil))
        }
        // Percussion staff never carries a key signature.
        #expect(!hasKeySignature(score, part: 2, measure: 0))
        // Bar 2's own change survives — this intent owns its span, not the whole score.
        #expect(score.activeKey(staff: Self.pianoStaff, measureIndex: 3) == 2)
    }

    @Test("the write and its re-spelling are one undo step, and the round trip is byte-exact")
    func setKeyIsOneUndoStepAndRoundTrips() {
        let original = fixture()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: -3))) // G → E♭ major
        // Intermediate state, asserted before the undo: a symmetric bug in apply and its inverse cancels invisibly
        // in the round trip alone.
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 0) == -3)
        #expect(accidental(session.score, part: 0, measure: 1) == .some(.sharp))
        #expect(session.canUndo)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("writing the key already in force resolves to nothing to apply")
    func setSameKeyPlansToNothing() {
        let score = fixture()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.setKeySignature(measureIndex: 0, concertKey: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    @Test("a mid-piece write replaces the change already there and leaves the span before it alone")
    func midPieceSetReplacesTheExistingChange() {
        let session = ScoreEditSession(score: fixture())
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: -1))) // D → F major at bar 2
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 3) == -1)
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 1) == 1) // span before untouched
        // Replaced in place rather than added alongside: bar 2 still declares exactly one key.
        let prefix = session.score.parts[0].staves[0].measures[2].voices[0].elements
            .filter { if case .keySignature = $0 { true } else { false } }
        #expect(prefix.count == 1)
        // F major spells F natural, so the F♯ chords in bars 2 and 3 need a glyph they did not need under D.
        #expect(accidental(session.score, part: 0, measure: 2) == .some(.sharp))
        #expect(accidental(session.score, part: 0, measure: 3) == .some(.sharp))
        #expect(accidental(session.score, part: 0, measure: 1) == .some(nil))
    }

    @Test("a bar that declares no key of its own gets one inserted, and undo takes it back out")
    func setKeyAtBarWithoutOneInsertsIt() {
        let original = fixture()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setKeySignature(measureIndex: 1, concertKey: -2))) // B♭ major from bar 1
        for part in [0, 1] {
            guard case let .keySignature(key) = session.score.parts[part].staves[0].measures[1].voices[0].elements[0]
            else { Issue.record("expected an inserted key signature at the head of bar 1"); return }
            #expect(key.concertKey == -2)
        }
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 1) == -2)
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 0) == 1) // bar 0 untouched
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 2) == 2) // bar 2 still wins its span
        // B♭ major spells F natural, so bar 1's F♯ needs a glyph; bar 2 belongs to D major and keeps none.
        #expect(accidental(session.score, part: 0, measure: 1) == .some(.sharp))
        #expect(accidental(session.score, part: 0, measure: 2) == .some(nil))
        #expect(!hasKeySignature(session.score, part: 2, measure: 1))
        #expect(session.undo())
        #expect(session.score == original)
    }

    /// The insertion path splices an element into the head of a voice's element list, which moves every index after
    /// it — including the ones a tuplet holds. And it has to land in MuseScore's structural order (clef, key, time)
    /// rather than simply at index 0, or the bar engraves its key before its own clef.
    @Test("an inserted key lands after the clef, before the time signature, and carries tuplets with it")
    func insertedKeyTakesTheCanonicalPositionAndShiftsTuplets() {
        var original = fixture()
        original.parts[0].staves[0].measures[1].voices[0].elements.insert(
            contentsOf: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
            ],
            at: 0,
        )
        original.parts[0].staves[0].measures[1].voices[0].tuplets = [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 2),
        ]
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setKeySignature(measureIndex: 1, concertKey: -2)))
        let voice = session.score.parts[0].staves[0].measures[1].voices[0]
        guard case .clef = voice.elements[0] else { Issue.record("the clef must stay first"); return }
        guard case let .keySignature(key) = voice.elements[1] else {
            Issue.record("the key belongs between the clef and the time signature"); return
        }
        #expect(key.concertKey == -2)
        guard case .timeSignature = voice.elements[2] else { Issue.record("the time signature follows"); return }
        #expect(voice.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 3, endIndex: 3)])
        #expect(session.undo())
        #expect(session.score == original)
    }

    // MARK: - .removeKeySignature

    @Test("removing a change reverts its span to the prevailing key, and undo puts it back exactly")
    func removeKeyRevertsToPrevailingAndRoundTrips() {
        let original = fixture()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.removeKeySignature(measureIndex: 2)))
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 3) == 1) // back to G major
        for part in [0, 1] {
            #expect(!hasKeySignature(session.score, part: part, measure: 2))
        }
        #expect(session.undo())
        #expect(session.score == original)
        #expect(session.score.activeKey(staff: Self.pianoStaff, measureIndex: 3) == 2)
    }

    /// The mirror of the insertion's tuplet shift: dropping the key moves every element behind it one index down,
    /// and a tuplet still has to point at the same notes afterwards.
    @Test("removing a key shifts the tuplets behind it back, and undo restores their indices")
    func removalShiftsTupletsBack() {
        var original = fixture()
        original.parts[0].staves[0].measures[2].voices[0].tuplets = [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 1),
        ]
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.removeKeySignature(measureIndex: 2)))
        #expect(session.score.parts[0].staves[0].measures[2].voices[0].tuplets == [
            Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 0),
        ])
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("the score's opening signature cannot be removed")
    func removeAtMeasureZeroIsRefused() {
        let score = fixture()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.removeKeySignature(measureIndex: 0)))
        #expect(session.lastRefusal?.reason == .cannotRemoveInitialSignature)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    @Test("removing where no explicit change exists resolves to nothing to apply")
    func removeWhereNoChangeExistsPlansToNothing() {
        let score = fixture()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.removeKeySignature(measureIndex: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }
}
