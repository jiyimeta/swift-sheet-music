import SheetMusicFoundation

extension Score {
    /// Returns a copy of the score with redundant auto-computed
    /// accidentals hidden, matching MuseScore's engraving behavior.
    ///
    /// MuseScore stores an accidental glyph on every altered note but
    /// only *draws* it when the alteration differs from what the reader
    /// already expects on that staff line — the key signature plus any
    /// earlier accidental in the same measure. A note whose alteration
    /// is already in force carries an AUTO-role accidental that
    /// MuseScore suppresses; a USER-role accidental (one the user
    /// explicitly forced, `<role>1</role>`) is always kept, even when
    /// redundant (a courtesy / cautionary accidental).
    ///
    /// This reproduces that suppression so a faithfully rendered score
    /// doesn't show duplicate sharps / flats / naturals. It is
    /// conservative: any note whose written `(letter, octave,
    /// alteration)` cannot be reliably derived from its `tpc` / `pitch`
    /// is left untouched, USER-role accidentals are never removed, and
    /// only standard accidentals (whose alteration the `tpc` fully
    /// captures) are eligible for suppression.
    ///
    /// Mirrors `mu::engraving::AccidentalState`, seeded per measure from
    /// the active key signature and updated as notes are read in tick
    /// order. Suppression is applied per staff (each staff has its own
    /// accidental state) and reset at every measure boundary.
    ///
    /// A tied note spelled like the note it is tied from draws no automatic accidental — the tie carries the
    /// alteration, and MuseScore takes such a glyph off (`Chord::cmdUpdateNotes`). A note tied over the barline that
    /// draws none has not shown the reader its alteration in this bar, so its line is marked
    /// (`AccidentalLineState.tiedOver`, MuseScore's `TIE_CONTEXT`) and the next note on it keeps its accidental even
    /// when the alteration is the same. A tie that changes the spelling (F♯ held on as G♭) is read like any other
    /// note.
    ///
    /// Two notes of one chord on the same line at different alterations (F and F♯) both keep their accidental, even
    /// where the state already covers one of them (`AccidentalLineState.hasAlteredUnison`).
    ///
    /// Grace notes are read in MuseScore's order — a chord's graces before, then the chord, then its graces after
    /// (`MeasureAccidentalWalk`) — and suppressed like any other note.
    ///
    /// **A percussion staff draws no accidental at all** — a drumset part
    /// (`Instrument.useDrumset`) or a `"percussion"` staff, the pair
    /// `RangeEditPlanner.isPitched` also reads. A drum note's pitch picks
    /// a kit piece and its line comes from the drumset, so an accidental
    /// has nothing to alter; MuseScore never computes one for a drum note
    /// (`Chord::cmdUpdateNotes` takes its PERCUSSION branch, which only
    /// re-lines the notes). One that reached the model anyway — an edit
    /// that treated a kit piece as a pitch, which swapped the snare for a
    /// C♯ — is dropped here, grace notes included, rather than drawn.
    public func suppressingRedundantAccidentals() -> Score {
        var copy = self
        let division = copy.division
        for partIndex in copy.parts.indices {
            let isDrumset = copy.parts[partIndex].instrument.useDrumset
            for staffIndex in copy.parts[partIndex].staves.indices {
                copy.parts.updateValue(at: partIndex) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        if isDrumset || staffValue.group == "percussion" {
                            Self.dropAccidentals(in: &staffValue)
                        } else {
                            Self.suppressInStaff(
                                &staffValue,
                                division: division,
                            )
                        }
                    }
                }
            }
        }
        return copy
    }

    /// Every note on `staff` — grace notes too — without its accidental.
    private static func dropAccidentals(in staff: inout Staff) {
        func stripped(_ note: inout Note) {
            note.accidental = nil
            note.accidentalBracket = .none
        }
        for measureIndex in staff.measures.indices {
            for voiceIndex in staff.measures[measureIndex].voices.indices {
                let elements = staff.measures[measureIndex].voices[voiceIndex].elements
                for elementIndex in elements.indices {
                    guard case var .chord(chord) = elements[elementIndex] else { continue }
                    let graces = chord.graceNotesBefore.values + chord.graceNotesAfter.values
                    let carriesOne = chord.notes.contains { $0.accidental != nil }
                        || graces.contains { $0.notes.contains { $0.accidental != nil } }
                    guard carriesOne else { continue }
                    for noteIndex in chord.notes.indices {
                        chord.notes.updateNote(at: noteIndex, stripped)
                    }
                    for graceIndex in chord.graceNotesBefore.indices {
                        chord.graceNotesBefore.updateValue(at: graceIndex) { grace in
                            for noteIndex in grace.notes.indices {
                                grace.notes.updateNote(at: noteIndex, stripped)
                            }
                        }
                    }
                    for graceIndex in chord.graceNotesAfter.indices {
                        chord.graceNotesAfter.updateValue(at: graceIndex) { grace in
                            for noteIndex in grace.notes.indices {
                                grace.notes.updateNote(at: noteIndex, stripped)
                            }
                        }
                    }
                    staff.measures[measureIndex].voices[voiceIndex].elements
                        .updateValue(at: elementIndex) { $0 = .chord(chord) }
                }
            }
        }
    }

    private static func suppressInStaff(_ staff: inout Staff, division: Int) {
        let durations = staff.measures.effectiveMeasureDurations()
        // Active concert-key value carried across measures. Updated from
        // each measure's voice-0 key signatures (last one wins), mirroring
        // `Score.activeKey`'s per-measure coarsening.
        var currentKey = 0
        // Ties are paired against the measures as given; suppression only ever takes glyphs off, never a tpc.
        let measures = staff.measures
        let crossVoice = CrossVoiceTies.links(in: measures)
        for measureIndex in staff.measures.indices {
            if let leading = staff.measures[measureIndex].voices.first {
                for el in leading.elements {
                    if case let .keySignature(k) = el {
                        currentKey = k.concertKey
                    }
                }
            }
            let dur = measureIndex < durations.count
                ? durations[measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            suppressInMeasure(
                &staff.measures[measureIndex],
                key: currentKey,
                division: division,
                measureDuration: dur,
                tieStarts: MeasureAccidentalWalk.tieStartTPCs(
                    in: measures, measureIndex: measureIndex, crossVoice: crossVoice,
                ),
            )
        }
    }

    /// One staff line, identified by its WRITTEN letter (0=C … 6=B) and
    /// written octave. Two enharmonic spellings (C♯4 vs D♭4) are
    /// different lines and so have independent accidental state.
    private struct LineKey: Hashable {
        let letter: Int
        let octave: Int
    }

    private static func suppressInMeasure(
        _ measure: inout Measure,
        key: Int,
        division: Int,
        measureDuration: Fraction,
        tieStarts: [MeasureAccidentalWalk.MainAddress: Int],
    ) {
        // Per-letter alteration implied by the key signature. Seeds the
        // state's default for each line.
        let keyAlteration = keyAlterationByLetter(forKey: key)
        let refs = MeasureAccidentalWalk.noteRefs(in: measure, division: division, measureDuration: measureDuration)

        // Accidental state: written line → alteration currently in force, and whether it arrived only through a tie
        // from the previous bar (`AccidentalLineState.tiedOver` — the next note on that line keeps its accidental).
        // Reset (empty) at the start of each measure; an absent line defaults to the key signature's alteration for
        // that letter.
        var state: [LineKey: AccidentalLineState] = [:]

        for ref in refs {
            guard let note = MeasureAccidentalWalk.note(at: ref, in: measure.voices) else { continue }

            guard let spelled = AccidentalLineState.spelling(pitch: note.pitch, tpc: note.tpc) else {
                // Can't reliably derive the written line / alteration —
                // never suppress, and don't disturb the state.
                continue
            }
            let lineKey = LineKey(letter: spelled.letter, octave: spelled.octave)
            let current = state[lineKey] ?? AccidentalLineState(alteration: keyAlteration[spelled.letter] ?? 0)

            var draws = note.accidental != nil
            if let accidental = note.accidental {
                // MuseScore's `Note::updateAccidental`: a note the state asks to speak does, unless a tie that keeps
                // its spelling carries the alteration; one the state covers speaks only to tell an altered unison
                // apart.
                let speaks = if current.needsAccidental(for: spelled.alteration) {
                    note.tieBack == nil || ref.mainAddress.flatMap { tieStarts[$0] } != note.tpc
                } else {
                    MeasureAccidentalWalk.hasAlteredUnison(at: ref, in: measure.voices)
                }
                if !speaks,
                   note.accidentalRole == .auto,
                   isStandardAccidental(accidental)
                {
                    MeasureAccidentalWalk.updateNote(at: ref, in: &measure.voices) {
                        $0.accidental = nil
                        $0.accidentalBracket = .none
                    }
                    draws = false
                }
                // Otherwise the accidental is needed, USER-forced, or
                // non-standard — keep it.
            }
            // The written alteration is now in force on this line for any
            // following note, whether or not a glyph was drawn.
            state[lineKey] = current.after(note, alteration: spelled.alteration, drawsAccidental: draws)
        }
    }

    // MARK: - Key signature

    /// Per-letter alteration (`0`, `+1`, or `−1`) implied by a concert-key
    /// value, keyed by letter index (0=C … 6=B). Sharps follow the circle
    /// of fifths `F C G D A E B`; flats follow `B E A D G C F`.
    private static func keyAlterationByLetter(forKey key: Int) -> [Int: Int] {
        // Letter indices (0=C … 6=B) in sharp / flat order.
        let sharpOrder = [3, 0, 4, 1, 5, 2, 6] // F C G D A E B
        let flatOrder = [6, 2, 5, 1, 4, 0, 3] // B E A D G C F
        var map: [Int: Int] = [:]
        if key > 0 {
            for i in 0 ..< min(key, 7) {
                map[sharpOrder[i]] = 1
            }
        } else if key < 0 {
            for i in 0 ..< min(-key, 7) {
                map[flatOrder[i]] = -1
            }
        }
        return map
    }

    /// Whether an accidental's alteration is fully captured by the `tpc`
    /// (so a `tpc`-derived "redundant" decision is reliable). Microtonal
    /// and courtesy-combination glyphs are excluded — they are kept.
    private static func isStandardAccidental(_ accidental: Accidental) -> Bool {
        switch accidental {
        case .flat, .natural, .sharp, .doubleFlat, .doubleSharp,
             .tripleFlat, .tripleSharp:
            true
        default:
            false
        }
    }
}
