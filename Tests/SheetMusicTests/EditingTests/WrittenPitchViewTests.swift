@testable import SheetMusicCore
import Testing

@Suite("Written-pitch view")
struct WrittenPitchViewTests {
    /// Part 0: flute (concert), part 1: B♭ clarinet — both one G staff, C major, one whole note concert B♭4.
    private func ensemble() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "flute", staves: [.init(clefType: "G")]),
                .init(
                    instrumentID: "clarinet",
                    staves: [.init(clefType: "G")],
                    transposeDiatonic: -1,
                    transposeChromatic: -2,
                ),
            ],
            measureCount: 1,
        ))
        for partIndex in score.parts.indices {
            score.parts.updateValue(at: partIndex) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[0].voices[0].elements.updateValue(at: 2) {
                        $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
                    }
                }
            }
        }
        return score
    }

    private func chord(_ score: Score, part: Int, measure: Int, element: Int) -> Chord? {
        guard case let .chord(c) = score.parts[part].staves[0]
            .measures[measure].voices[0].elements[element] else { return nil }
        return c
    }

    private func key(_ score: Score, part: Int, measure: Int, element: Int) -> Int? {
        guard case let .keySignature(k) = score.parts[part].staves[0]
            .measures[measure].voices[0].elements[element] else { return nil }
        return k.concertKey
    }

    @Test func transposingPartMovesConcertPartStays() {
        let written = ensemble().writtenPitchView()
        // Flute untouched.
        guard let flute = chord(written, part: 0, measure: 0, element: 2) else {
            Issue.record("flute")
            return
        }
        #expect(flute.notes.first?.pitch == 70)
        #expect(flute.notes.first?.tpc == 12)
        #expect(key(written, part: 0, measure: 0, element: 0) == 0)
        // Clarinet: concert B♭4 displays as written C5; key sig C major stays 0 + 2 = D major.
        guard let cl = chord(written, part: 1, measure: 0, element: 2) else {
            Issue.record("clarinet")
            return
        }
        #expect(cl.notes.first?.pitch == 72)
        #expect(cl.notes.first?.tpc == 14)
        #expect(key(written, part: 1, measure: 0, element: 0) == 2)
    }

    @Test func nonTransposingScoreReturnsSelf() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T", parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 1,
        ))
        #expect(score.writtenPitchView() == score)
    }

    /// Tick structure, IDs and element ordering must be untouched — the view is display-only and playback keeps
    /// reading the concert score through the same addresses.
    @Test func elementShapeIsUnchanged() {
        let score = ensemble()
        let written = score.writtenPitchView()
        #expect(written.parts.count == score.parts.count)
        for partIndex in score.parts.indices {
            let before = score.parts[partIndex].staves[0].measures[0].voices[0].elements
            let after = written.parts[partIndex].staves[0].measures[0].voices[0].elements
            #expect(before.count == after.count)
            #expect(
                before.map { $0.tickCount(division: score.division) }
                    == after.map { $0.tickCount(division: written.division) },
            )
        }
    }

    /// The in-loop `useDrumset` guard, not the top-level fast path: a SECOND transposing part (an F horn,
    /// `writtenFifthsOffset +1`) keeps `writtenPitchView()` past its early return, so the loop actually runs and
    /// has to skip the drumset part on its own. Without the horn the whole score short-circuits to `self` and the
    /// guard is never reached.
    @Test func drumsetPartIsNotShifted() {
        var score = ensemble()
        score.parts.updateValue(at: 1) { partValue in
            partValue.instrument.useDrumset = true
        }
        var hornStaff = score.parts[0].staves[0]
        hornStaff.measures[0].voices[0].elements.updateValue(at: 2) {
            $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        }
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        score.parts.insert(Part(
            id: "3",
            instrument: Instrument(id: "horn", transposeDiatonic: -4, transposeChromatic: -7),
            staves: [hornStaff],
        ), after: score.parts.eid(at: score.parts.count - 1), id: ids.next())

        let written = score.writtenPitchView()
        // The drumset clarinet is untouched — pitch, spelling and key signature all stay concert.
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.pitch == 70)
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.tpc == 12)
        #expect(key(written, part: 1, measure: 0, element: 0) == 0)
        #expect(written.parts[1] == score.parts[1])
        // …while the horn beside it did move, proving the loop ran rather than short-circuiting.
        #expect(chord(written, part: 2, measure: 0, element: 2)?.notes.first?.pitch == 77)
        #expect(chord(written, part: 2, measure: 0, element: 2)?.notes.first?.tpc == 13)
        #expect(key(written, part: 2, measure: 0, element: 0) == 1)
    }

    @Test func percussionStaffIsNotShifted() {
        var score = ensemble()
        score.parts.updateValue(at: 1) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.group = "percussion"
            }
        }
        let written = score.writtenPitchView()
        #expect(chord(written, part: 1, measure: 0, element: 2)?.notes.first?.pitch == 70)
        #expect(key(written, part: 1, measure: 0, element: 0) == 0)
    }

    /// Chord symbols move with the notes so a lead sheet's symbols keep naming what is written under them.
    @Test func harmonyMovesWithTheNotes() throws {
        var score = ensemble()
        var slots = score.parts[1].staves[0].measures[0].voices[0].elements.voiceSlots()
        slots.append(VoiceSlot(identity: .fresh, element: .harmony(Harmony(name: "7", rootTpc: 12, bassTpc: 12))))
        try ReplaceVoiceElements(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, slots: slots,
            tuplets: score.parts[1].staves[0].measures[0].voices[0].tuplets,
        ).apply(to: &score)
        let written = score.writtenPitchView()
        guard case let .harmony(h) = written.parts[1].staves[0].measures[0].voices[0].elements[3]
        else {
            Issue.record("harmony")
            return
        }
        #expect(h.rootTpc == 14)
        #expect(h.bassTpc == 14)
    }

    /// A measure that inherits its key from an EARLIER measure must resolve that key against the original score.
    /// Resolving it against the partially rewritten copy reads a key that has already been shifted once and shifts
    /// it again: here measure 2 inherits B major (+5); the correct written key context is +7 (fifthsDelta +2, D →
    /// E), while a copy-resolved read would see +7 already, respell 9 → −3 and move the note by −10 fifths instead.
    @Test func midScoreKeyChangeIsResolvedAgainstTheOriginalScore() throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            // writtenFifthsOffset == +2
            parts: [.init(
                instrumentID: "clarinet",
                staves: [.init(clefType: "G")],
                transposeDiatonic: -1,
                transposeChromatic: -2,
            )],
            concertKey: 3, measureCount: 3,
        ))
        // Measure 1 modulates to B major (+5); measure 2 inherits it and carries the note.
        var slots = score.parts[0].staves[0].measures[1].voices[0].elements.voiceSlots()
        slots.insert(VoiceSlot(identity: .fresh, element: .keySignature(KeySignature(concertKey: 5))), at: 0)
        try ReplaceVoiceElements(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1, voiceIndex: 0, slots: slots,
            tuplets: score.parts[0].staves[0].measures[1].voices[0].tuplets,
        ).apply(to: &score)
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[2].voices[0].elements.updateValue(at: 0) {
                    $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 74, tpc: 16)]))
                } // concert D5
            }
        }

        let written = score.writtenPitchView()
        #expect(key(written, part: 0, measure: 0, element: 0) == 5) // A → B
        #expect(key(written, part: 0, measure: 1, element: 0) == 7) // B → C♯
        // Concert D5 (tpc 16) written as E5 (tpc 18) — a +2 fifths shift, not the −10 a double-shift would give.
        let note = chord(written, part: 0, measure: 2, element: 0)?.notes.first
        #expect(note?.pitch == 76)
        #expect(note?.tpc == 18)
    }

    // MARK: - Clefs and accidentals a player reads

    /// One electric-bass measure (sounds an octave below written, `writtenFifthsOffset` 0) under concert E♭ major:
    /// `elements[0]` is `clef`, `[1]` the key signature, then one eighth-note chord per note.
    private func bass(clef: Clef, notes: [Note], instrumentID: String = "electric-bass") -> Score {
        let elements: [VoiceElement] = [.clef(clef), .keySignature(KeySignature(concertKey: -3))]
            + notes.map { .chord(Chord(duration: .eighth, notes: ChordNotes([$0]))) }
        let staff = Staff(group: "pitched", defaultClefType: "F", measures: [
            Measure(voices: [Voice(elements: elements)]),
        ])
        let instrument = Instrument(id: instrumentID, transposeDiatonic: -7, transposeChromatic: -12)
        return Score(division: 480, parts: [Part(id: "p0", instrument: instrument, staves: [staff])])
    }

    private func clef(_ score: Score, part: Int = 0, measure: Int = 0, element: Int = 0) -> Clef? {
        guard case let .clef(c) = score.parts[part].staves[0].measures[measure].voices[0].elements[element]
        else { return nil }
        return c
    }

    /// MuseScore shows `<transposingClefType>` whenever Concert Pitch is off, which is the view this is. A bass
    /// part saved with an F 8va transposing clef over an F 8vb concert one must read F 8va: drawing the concert
    /// clef over written-pitch notes puts every note two octaves away from where the player expects it.
    @Test func showsTheTransposingClef() {
        let score = bass(
            clef: Clef(concertClefType: "F8vb", transposingClefType: "F8va"),
            notes: [Note(pitch: 41, tpc: 13)],
        )
        #expect(clef(score.writtenPitchView())?.concertClefType == "F8va")
        // The stored score keeps both, so a save writes back exactly what was read.
        #expect(clef(score)?.concertClefType == "F8vb")
    }

    /// A clef with no transposing type (every clef folino writes itself) shows its concert type.
    @Test func clefWithoutATransposingTypeShowsItsConcertType() {
        let score = bass(clef: Clef(concertClefType: "F8vb"), notes: [Note(pitch: 41, tpc: 13)])
        #expect(clef(score.writtenPitchView())?.concertClefType == "F8vb")
    }

    /// The transposing clef is a property of the view, not of the instrument: a concert-pitch part whose clef
    /// carries a different transposing type reads that type too, and keeps the fast path's identity otherwise.
    @Test func concertPartShowsItsTransposingClefToo() {
        var score = bass(clef: Clef(concertClefType: "G", transposingClefType: "G8vb"), notes: [])
        score.parts.updateValue(at: 0) { partValue in
            partValue.instrument.transposeDiatonic = 0
            partValue.instrument.transposeChromatic = 0
        }
        #expect(clef(score.writtenPitchView())?.concertClefType == "G8vb")
    }

    /// An accidental the BAR asks for, not the key: under E♭ major an A♮ earlier in the bar means the A♭ after it
    /// needs its ♭ back. The file stores that ♭; the view must keep it rather than re-derive the glyph from the key
    /// signature alone, which says A♭ needs nothing.
    @Test func keepsAnAccidentalTheBarCallsFor() {
        let score = bass(
            clef: Clef(concertClefType: "F8vb", transposingClefType: "F8va"),
            notes: [
                Note(pitch: 45, tpc: 17, accidental: .natural), // A♮
                Note(pitch: 44, tpc: 10, accidental: .flat), // A♭, cancelling the ♮
                Note(pitch: 44, tpc: 10), // A♭ again — the ♭ is already in force
            ],
        )
        let written = score.writtenPitchView()
        #expect(chord(written, part: 0, measure: 0, element: 2)?.notes.first?.accidental == .natural)
        #expect(chord(written, part: 0, measure: 0, element: 3)?.notes.first?.accidental == .flat)
        #expect(chord(written, part: 0, measure: 0, element: 4)?.notes.first?.accidental == nil)
    }

    /// The same bar on a part that moves along the line of fifths: a B♭ clarinet reads concert E♭ major as F
    /// major, so the ♮ lands on B and the cancelling ♭ comes back as B♭ — a glyph its key signature would drop.
    @Test func cancellingAccidentalSurvivesAFifthsShift() {
        var score = bass(
            clef: Clef(concertClefType: "G"),
            notes: [
                Note(pitch: 69, tpc: 17, accidental: .natural), // A♮4
                Note(pitch: 68, tpc: 10, accidental: .flat), // A♭4
                Note(pitch: 68, tpc: 10), // A♭4, covered
            ],
        )
        score.parts.updateValue(at: 0) { partValue in
            partValue.instrument.transposeDiatonic = -1
            partValue.instrument.transposeChromatic = -2
        }
        let written = score.writtenPitchView()
        let notes = (2 ... 4).map { chord(written, part: 0, measure: 0, element: $0)?.notes.first }
        #expect(notes.map { $0?.tpc } == [19, 12, 12]) // B♮, B♭, B♭
        #expect(notes.map { $0?.accidental } == [.natural, .flat, nil])
    }
}
