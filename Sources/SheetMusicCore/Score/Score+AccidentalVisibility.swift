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
    /// Note: grace notes are intentionally left untouched (their glyphs
    /// are always kept and they don't update the state) — a conservative
    /// choice, since a wrongly-suppressed grace accidental is worse than
    /// a redundant one.
    public func suppressingRedundantAccidentals() -> Score {
        var copy = self
        let division = copy.division
        for partIndex in copy.parts.indices {
            for staffIndex in copy.parts[partIndex].staves.indices {
                Self.suppressInStaff(
                    &copy.parts[partIndex].staves[staffIndex],
                    division: division,
                )
            }
        }
        return copy
    }

    private static func suppressInStaff(_ staff: inout Staff, division: Int) {
        let durations = staff.measures.effectiveMeasureDurations()
        // Active concert-key value carried across measures. Updated from
        // each measure's voice-0 key signatures (last one wins), mirroring
        // `Score.activeKey`'s per-measure coarsening.
        var currentKey = 0
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
    ) {
        // Per-letter alteration implied by the key signature. Seeds the
        // state's default for each line.
        let keyAlteration = keyAlterationByLetter(forKey: key)

        // A reference to one note, with its onset tick, so the measure's
        // notes can be processed in tick order across every voice.
        struct NoteRef {
            let tick: Int
            let voice: Int
            let element: Int
            let note: Int
        }
        var refs: [NoteRef] = []
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                if case let .chord(chord) = element {
                    for noteIndex in chord.notes.indices {
                        refs.append(NoteRef(
                            tick: tick,
                            voice: voiceIndex,
                            element: elementIndex,
                            note: noteIndex,
                        ))
                    }
                }
                tick += element.tickCount(
                    division: division, in: measureDuration,
                ) ?? 0
            }
        }
        // Tick order; ties broken by voice then in-chord index so the
        // result is deterministic.
        refs.sort { lhs, rhs in
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            if lhs.voice != rhs.voice { return lhs.voice < rhs.voice }
            return lhs.note < rhs.note
        }

        // Accidental state: written line → alteration currently in force.
        // Reset (empty) at the start of each measure; an absent line
        // defaults to the key signature's alteration for that letter.
        var state: [LineKey: Int] = [:]

        for ref in refs {
            guard case let .chord(chord) =
                measure.voices[ref.voice].elements[ref.element]
            else { continue }
            let note = chord.notes[ref.note]

            guard let spelled = spelling(pitch: note.pitch, tpc: note.tpc) else {
                // Can't reliably derive the written line / alteration —
                // never suppress, and don't disturb the state.
                continue
            }
            let lineKey = LineKey(letter: spelled.letter, octave: spelled.octave)
            let current = state[lineKey] ?? keyAlteration[spelled.letter] ?? 0

            if let accidental = note.accidental {
                let isRedundant = spelled.alter == current
                if isRedundant,
                   note.accidentalRole == .auto,
                   isStandardAccidental(accidental)
                {
                    var mutated = chord
                    mutated.notes[ref.note].accidental = nil
                    mutated.notes[ref.note].accidentalBracket = .none
                    measure.voices[ref.voice].elements[ref.element] = .chord(mutated)
                }
                // Otherwise the accidental is needed, USER-forced, or
                // non-standard — keep it.
            }
            // The written alteration is now in force on this line for any
            // following note, whether or not a glyph was drawn.
            state[lineKey] = spelled.alter
        }
    }

    // MARK: - TPC / pitch spelling

    /// TPC of each natural letter, in `C D E F G A B` order.
    private static let naturalTpcByLetter = [14, 16, 18, 13, 15, 17, 19]
    /// Semitone offset of each natural letter from C, `C D E F G A B`.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    /// Derive the WRITTEN `(letter, octave, alteration)` of a note from
    /// its `tpc` and MIDI `pitch`. Returns `nil` when the pair is outside
    /// MuseScore's valid TPC range or is internally inconsistent (the
    /// `tpc`-implied pitch class disagrees with the MIDI pitch) — callers
    /// must treat that as "do not suppress".
    ///
    /// `letter` is 0=C … 6=B; `octave` is the scientific octave of the
    /// written note (middle C = octave 4); `alteration` is the chromatic
    /// shift from the natural (♮=0, ♯=+1, ♭=−1, ×=+2, ♭♭=−2).
    private static func spelling(
        pitch: Int, tpc: Int,
    ) -> (letter: Int, octave: Int, alter: Int)? {
        // MuseScore's Tpc range: TPC_MIN = -1 (F♭♭) … TPC_MAX = 33 (B♯♯).
        guard (-1 ... 33).contains(tpc) else { return nil }
        let letter = letterIndex(forTpc: tpc)
        // tpc = naturalTpc + 7 * alter, exactly.
        let alter = (tpc - naturalTpcByLetter[letter]) / 7
        let naturalSemi = naturalSemitoneByLetter[letter]
        // Consistency guard: the written pitch class must match the
        // actual MIDI pitch class. A mismatch means a corrupt or unusual
        // pitch+tpc pairing — bail rather than risk a wrong suppression.
        let expectedPC = ((naturalSemi + alter) % 12 + 12) % 12
        guard ((pitch % 12) + 12) % 12 == expectedPC else { return nil }
        let octave = (pitch - naturalSemi - alter) / 12 - 1
        return (letter, octave, alter)
    }

    /// Diatonic letter index (0=C … 6=B) of a `tpc`. Rotates the line of
    /// fifths (`F C G D A E B`) onto `C D E F G A B` order.
    private static func letterIndex(forTpc tpc: Int) -> Int {
        let table = [3, 0, 4, 1, 5, 2, 6]
        return table[((tpc + 1) % 7 + 7) % 7]
    }

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
