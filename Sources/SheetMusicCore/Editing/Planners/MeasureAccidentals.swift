import SheetMusicFoundation

/// MuseScore's `AccidentalState` (`engraving/dom/accidental.cpp`), as much of it as an editor needs.
///
/// Two questions, one piece of state. Which alteration is already IN FORCE on a written staff line — the key
/// signature, overridden by any accidental earlier in the same bar — decides both **what pitch a letter key writes**
/// (spec: a C key under D major writes C♯; after a C♮ earlier in the bar it writes C♮) and **whether the note needs
/// an accidental glyph at all** (the first C♮ under D major cancels the signature and prints ♮; a second one is
/// already covered and prints nothing).
///
/// The glyph half matters because `Note.accidental` is a STORED symbol, not something layout derives: ssm's
/// `Score.suppressingRedundantAccidentals()` only ever *removes* a redundant glyph, so a note written without one
/// is a note that will never show one. Keeping the stored glyphs true is therefore the editor's job — the same job
/// MuseScore does by re-running its accidental state over a measure after every edit that touches it.
public enum MeasureAccidentals {
    // MARK: - What a letter key writes

    /// Which octave of a letter a key writes, given the note it is measured against.
    ///
    /// The two are different questions, not settings on one. A letter key writing at the caret means "the nearest
    /// one to what I just played"; a letter key stacking onto a chord means "above what is already there" —
    /// MuseScore's own split (`Score::resolveNoteInputParams` branches on `addFlag` for exactly this).
    public enum LetterOctave: Sendable {
        /// The octave nearest the reference, preferring the higher on a tie. A caret letter key.
        case nearest
        /// The lowest octave strictly above the reference. A chord-add letter key.
        case above
    }

    /// Pitch and spelling for `letter` written at `location`, with `reference` (the previous note, or the chord
    /// being added to) choosing the octave per `octaveRule`, spelled with whatever alteration is in force on the
    /// staff line it lands on.
    ///
    /// The octave search runs against the letter's KEY spelling — the pitch a reader would expect for it — so that
    /// "nearest to the last note" means nearest as heard, then the bar's own accidental (if any) respells it.
    /// `.above` measures against that same key spelling, matching MuseScore, which strips the reference's own
    /// alteration before choosing.
    public static func plannedPitch(
        forLetter letter: Character,
        nearestTo reference: Int?,
        octaveRule: LetterOctave = .nearest,
        at location: VoiceElementID,
        in score: Score,
    ) -> (pitch: Int, tpc: Int)? {
        guard let natural = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) else { return nil }
        let keySig = score.activeKey(staff: location.staff, measureIndex: location.measureIndex)
        let letterIndex = AccidentalLineState.letter(forTpc: natural.tpc)
        let keyAlteration = keyAlteration(forLetter: letterIndex, keySig: keySig)
        let chosen: (pitch: Int, tpc: Int)?
        if let reference {
            let searchReference = reference - keyAlteration
            switch octaveRule {
            case .nearest:
                chosen = NoteInputPlanner.pitch(forLetter: letter, nearestTo: searchReference)
            case .above:
                chosen = NoteInputPlanner.pitch(forLetter: letter, above: searchReference)
            }
        } else {
            // Nothing was played, so the CLEF says where the staff lives — MuseScore's own rule for this branch,
            // and the reason A under a bass clef is the A in the first space rather than the A an octave-4 default
            // wrote three ledger lines above it. Reached for the first note of a staff, and again after every rest
            // the caret lands on with nothing before it, which on a fresh score is every note until the first one
            // lands. `.above` has no chord to stack onto here either, so both rules take the same answer rather
            // than one of them refusing the key.
            chosen = NoteInputPlanner.pitch(
                forLetter: letter, clefAnchor: score.clefInForce(at: location).middleLinePitch,
            )
        }
        guard let nearestNatural = chosen else { return nil }
        let octave = nearestNatural.pitch / 12 - 1
        let alteration = alteration(
            inForceOn: Line(letter: letterIndex, octave: octave), before: location, in: score, keySig: keySig,
        )
        let pitch = nearestNatural.pitch + alteration
        guard (0 ... 127).contains(pitch) else { return nil }
        return (pitch, natural.tpc + 7 * alteration)
    }

    /// `plannedPitch`, resolved in the WRITTEN space of the target staff: `letter` means the note the user SEES on
    /// that staff, and the returned `(pitch, tpc)` are the CONCERT values to store. Falls through to `plannedPitch`
    /// unchanged wherever `writtenPitchView()` would leave the staff alone (concert-pitch part, drumset,
    /// percussion).
    ///
    /// This is not a nicety on a transposing staff, it is the whole meaning of the key: a B♭ clarinet in concert C
    /// major reads D major, so the letter C means the C♯ that key signature already spells — concert B♮. Planning
    /// the same letter against the concert score writes a concert C, which that staff engraves as a D.
    ///
    /// `nearestTo` stays CONCERT at the call site (it comes from the previous note in the stored score); the
    /// conversion for the octave search happens here.
    ///
    /// `nil` also for a letter whose written pitch is fine but whose CONCERT pitch would fall outside MIDI's
    /// `0…127` — the guard `plannedPitch` applies to the pitch it returns says nothing about the pitch this
    /// stores, and on a transposing staff those are two different numbers.
    ///
    /// **Cost:** one `writtenPitchView()` — a full-score value copy — per call, i.e. per keystroke. Accepted
    /// rather than transformed in place because the octave search and the bar's accidental state both have to
    /// read the written key AND the written spelling of every earlier note in the measure, and only the view
    /// produces those consistently. The editor already re-lays-out the whole score on every keystroke, so this
    /// rides underneath work an order of magnitude larger; revisit it only if that stops being true.
    public static func plannedConcertPitch(
        forWrittenLetter letter: Character,
        nearestTo concertReference: Int?,
        octaveRule: LetterOctave = .nearest,
        at location: VoiceElementID,
        in score: Score,
    ) -> (pitch: Int, tpc: Int)? {
        let crossing = score.writtenSpaceCrossing(staff: location.staff, measureIndex: location.measureIndex)
        guard !crossing.isIdentity else {
            return plannedPitch(
                forLetter: letter, nearestTo: concertReference, octaveRule: octaveRule, at: location, in: score,
            )
        }
        // A staff's transposition is one interval applied to every note, so it preserves order: the highest concert
        // pitch in a chord is also its highest written one, and `.above` means the same thing on either side.
        guard let planned = plannedPitch(
            forLetter: letter,
            nearestTo: concertReference.map(crossing.writtenPitch),
            octaveRule: octaveRule,
            at: location,
            in: score.writtenPitchView(),
        ) else { return nil }
        return crossing.concert(planned)
    }

    // MARK: - Keeping the written glyphs true

    /// The glyph repairs `current` needs after an edit turned `previous` into it: every measure whose music changed,
    /// renotated. Empty when nothing changed, or when nothing in what changed affects a glyph.
    ///
    /// Measure-scoped because accidental state is: it is seeded from the key signature at every barline, so an edit
    /// can only ever disturb the bar it lands in. Comparing measures rather than trusting the command's reported
    /// location keeps chains that span bars (`CrossBarInputPlanner`) covered without special-casing them.
    ///
    /// **Percussion is skipped**, for `renotationCommands(in:measureRange:)`'s reason (drum bars got ♯/♭, 2026-09-22).
    public static func renotationCommands(in current: Score, changedFrom previous: Score) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        for (partIndex, part) in current.parts.enumerated() where !part.instrument.useDrumset {
            for (staffIndex, staff) in part.staves.enumerated() where staff.group != "percussion" {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                let before = previous[address]?.measures
                let durations = current.effectiveMeasureDurations(partIndex: partIndex, staffIndex: staffIndex)
                for (measureIndex, measure) in staff.measures.enumerated() {
                    let wasThere = before?.indices.contains(measureIndex) == true
                    guard !wasThere || before?[measureIndex] != measure,
                          durations.indices.contains(measureIndex)
                    else { continue }
                    commands.append(contentsOf: renotate(
                        measureIndex,
                        of: staff.measures,
                        at: address,
                        keySig: current.activeKey(staff: address, measureIndex: measureIndex),
                        division: current.division,
                        measureDuration: durations[measureIndex],
                    ))
                }
            }
        }
        return commands
    }

    /// The glyph repairs every measure in `measureRange` needs against the key in force **in `score` as given** —
    /// i.e. call this on a score that ALREADY carries the new signature, and it plans the notes that signature
    /// leaves mis-spelled.
    ///
    /// This is the signature-change counterpart to `renotationCommands(in:changedFrom:)`. That one diffs measures,
    /// so it can only reach bars whose bytes moved — and a key change moves exactly one bar (the one the new
    /// `KeySignature` element is written into) while silently re-reading every bar after it up to the next key
    /// change. Those bars are byte-identical and yet every accidental in them is now judged against a different
    /// signature, so the caller names the span instead of letting a diff find it.
    ///
    /// Percussion is skipped — unpitched staves have no key to be in or out of, and rewriting a drum note's glyph
    /// on tpc evidence would be meaningless. Same spelling as `AddPart.signatureReference(in:)`: a `useDrumset`
    /// part, or a staff whose `group` is `"percussion"`.
    ///
    /// The range is clamped per staff, so a span running past a short staff's last bar is a no-op there rather
    /// than a trap. Voices that come out identical produce no command, so an already-correct span returns empty.
    public static func renotationCommands(in score: Score, measureRange: Range<Int>) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        for (partIndex, part) in score.parts.enumerated() where !part.instrument.useDrumset {
            for (staffIndex, staff) in part.staves.enumerated() where staff.group != "percussion" {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                let durations = score.effectiveMeasureDurations(partIndex: partIndex, staffIndex: staffIndex)
                for measureIndex in measureRange.clamped(to: staff.measures.indices) {
                    guard durations.indices.contains(measureIndex) else { continue }
                    commands.append(contentsOf: renotate(
                        measureIndex,
                        of: staff.measures,
                        at: address,
                        keySig: score.activeKey(staff: address, measureIndex: measureIndex),
                        division: score.division,
                        measureDuration: durations[measureIndex],
                    ))
                }
            }
        }
        return commands
    }

    /// `measures[measureIndex]`'s voices rewritten with the glyphs its notes actually need — one
    /// `ReplaceVoiceElements` per voice that came out different, none for the voices that didn't. Grace notes are
    /// read and rewritten in MuseScore's order (`MeasureAccidentalWalk`).
    ///
    /// A tied note follows MuseScore's tie rule (`Chord::cmdUpdateNotes`): spelled like the note it is tied from, it
    /// draws no glyph, since the tie carries the alteration — and it marks its line (`AccidentalLineState.tiedOver`),
    /// so the next note there restates its accidental. Spelled otherwise (F♯ held on as G♭) it is renotated like any
    /// other note. Two notes of one chord on the same line at different alterations (F and F♯) both get their glyph,
    /// even where the state already covers one of them (`AccidentalLineState.hasAlteredUnison`).
    ///
    /// Four kinds of note are read for their alteration but never rewritten:
    ///
    /// - a note whose written `(letter, octave, alteration)` can't be derived from its `pitch` / `tpc` — nothing
    ///   reliable can be said about it, so it also doesn't update the state;
    /// - a USER-forced accidental — a courtesy the user asked for, which is theirs to remove;
    /// - a glyph that says more than the tpc knows (microtonal, courtesy combination);
    /// - a tied note whose start can't be found (`MeasureAccidentalWalk.tieStartTPCs`).
    private static func renotate(
        _ measureIndex: Int,
        of measures: [Measure],
        at staff: StaffAddress,
        keySig: Int,
        division: Int,
        measureDuration: Fraction,
    ) -> [any EditCommand] {
        let measure = measures[measureIndex]
        let tieStarts = MeasureAccidentalWalk.tieStartTPCs(
            in: measures, measureIndex: measureIndex,
            crossVoice: CrossVoiceTies.links(in: measures, sourceMeasures: max(measureIndex - 1, 0) ... measureIndex),
        )
        var voices = measure.voices
        var state: [Line: AccidentalLineState] = [:]
        for ref in MeasureAccidentalWalk.noteRefs(in: measure, division: division, measureDuration: measureDuration) {
            guard let note = MeasureAccidentalWalk.note(at: ref, in: voices),
                  let written = AccidentalLineState.spelling(pitch: note.pitch, tpc: note.tpc)
            else { continue }
            let line = Line(letter: written.letter, octave: written.octave)
            let inForce = state[line]
                ?? AccidentalLineState(alteration: keyAlteration(forLetter: written.letter, keySig: keySig))
            var drawn = note.accidental
            if let wanted = glyph(
                for: note, alteration: written.alteration, against: inForce,
                tiedFrom: ref.mainAddress.flatMap { tieStarts[$0] },
                alteredUnison: MeasureAccidentalWalk.hasAlteredUnison(at: ref, in: voices),
            ), wanted != note.accidental {
                MeasureAccidentalWalk.updateNote(at: ref, in: &voices) {
                    $0.accidental = wanted
                    $0.accidentalBracket = wanted == nil ? .none : note.accidentalBracket
                }
                drawn = wanted
            }
            state[line] = inForce.after(note, alteration: written.alteration, drawsAccidental: drawn != nil)
        }
        return voices.indices.compactMap { voiceIndex in
            guard voices[voiceIndex] != measure.voices[voiceIndex] else { return nil }
            return ReplaceVoiceElements(
                staff: staff,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elements: voices[voiceIndex].elements,
                tuplets: voices[voiceIndex].tuplets,
            )
        }
    }

    // MARK: - The state itself

    /// One written staff line. Two enharmonic spellings (C♯4 and D♭4) are different lines and so carry independent
    /// state — which is why this is keyed by the WRITTEN letter and octave rather than by sounding pitch.
    private struct Line: Hashable {
        let letter: Int
        let octave: Int
    }

    /// The glyph `note` should carry against `inForce`, or nil (outer) to leave the one it has — `tiedFrom` is the
    /// tpc of the note it is tied from, when it is tied back and that start was found, and `alteredUnison` whether
    /// another note of its chord stands on its line at a different alteration.
    ///
    /// MuseScore's `Note::updateAccidental`: a note the state asks to speak does, unless a tie that keeps its spelling
    /// carries the alteration; one the state covers speaks only to tell an altered unison apart.
    private static func glyph(
        for note: Note, alteration: Int, against inForce: AccidentalLineState, tiedFrom: Int?, alteredUnison: Bool,
    ) -> Accidental?? {
        guard note.accidentalRole != .user else { return nil }
        if let existing = note.accidental, !isStandard(existing) { return nil }
        let needed = inForce.needsAccidental(for: alteration)
        if note.tieBack != nil {
            guard let tiedFrom else { return nil }
            if needed, tiedFrom == note.tpc { return .some(nil) }
        }
        guard needed || alteredUnison else { return .some(nil) }
        // An alteration no single glyph can spell: saying nothing beats clearing the sign it has.
        return AccidentalLineState.glyph(forAlteration: alteration).map { .some($0) }
    }

    /// The alteration a reader already has in force on `line` when they reach `location`: the last one written on
    /// that line earlier in the bar, or the key signature's when the bar hasn't spoken about it yet.
    ///
    /// A note tied into the bar that draws no accidental is not "written" here — the reader never saw its alteration
    /// in this bar — so it is read past, as MuseScore's `Measure::findAccidental` reads past it. Grace notes of the
    /// earlier chords count, as they do there.
    private static func alteration(
        inForceOn line: Line, before location: VoiceElementID, in score: Score, keySig: Int,
    ) -> Int {
        let fallback = keyAlteration(forLetter: line.letter, keySig: keySig)
        guard let staff = score[location.staff],
              staff.measures.indices.contains(location.measureIndex)
        else { return fallback }
        let measure = staff.measures[location.measureIndex]
        let durations = score.effectiveMeasureDurations(
            partIndex: location.staff.partIndex, staffIndex: location.staff.staffIndexInPart,
        )
        guard durations.indices.contains(location.measureIndex) else { return fallback }
        let measureDuration = durations[location.measureIndex]
        let division = score.division
        guard measure.voices.indices.contains(location.voiceIndex) else { return fallback }
        let cutoff = tickOffset(
            in: measure.voices[location.voiceIndex], before: location.elementIndex,
            division: division, measureDuration: measureDuration,
        )
        var alteration = fallback
        for ref in MeasureAccidentalWalk.noteRefs(in: measure, division: division, measureDuration: measureDuration) {
            guard ref.tick < cutoff else { break }
            guard let note = MeasureAccidentalWalk.note(at: ref, in: measure.voices),
                  !AccidentalLineState.isUnwrittenTie(note),
                  let written = AccidentalLineState.spelling(pitch: note.pitch, tpc: note.tpc),
                  written.letter == line.letter, written.octave == line.octave
            else { continue }
            alteration = written.alteration
        }
        return alteration
    }

    private static func tickOffset(
        in voice: Voice, before elementIndex: Int, division: Int, measureDuration: Fraction,
    ) -> Int {
        voice.elements.prefix(elementIndex).reduce(0) {
            $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0)
        }
    }

    // MARK: - Spelling

    /// The alteration a key signature of `keySig` puts on `letter` (0=C … 6=B). Reuses `StaffStepPitch`'s in-key
    /// window so the two paths can't drift apart.
    private static func keyAlteration(forLetter letter: Int, keySig: Int) -> Int {
        let natural = AccidentalLineState.naturalTpcByLetter[letter]
        return (StaffStepPitch.inKeyTpc(naturalTpc: natural, keySig: keySig) - natural) / 7
    }

    /// Whether an accidental's alteration is fully captured by the tpc, and so may be replaced on tpc evidence
    /// alone. Microtonal and courtesy-combination glyphs say more than the tpc knows — those are left alone.
    private static func isStandard(_ accidental: Accidental) -> Bool {
        switch accidental {
        case .flat, .natural, .sharp, .doubleFlat, .doubleSharp, .tripleFlat, .tripleSharp: true
        default: false
        }
    }
}
