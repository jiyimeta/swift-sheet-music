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

    /// Pitch and spelling for `letter` written at `location`, with `reference` (the previous note) choosing the
    /// octave: the nearest octave of that letter, spelled with whatever alteration is in force on the staff line it
    /// lands on.
    ///
    /// The octave search runs against the letter's KEY spelling — the pitch a reader would expect for it — so that
    /// "nearest to the last note" means nearest as heard, then the bar's own accidental (if any) respells it.
    public static func plannedPitch(
        forLetter letter: Character,
        nearestTo reference: Int?,
        at location: VoiceElementID,
        in score: Score,
    ) -> (pitch: Int, tpc: Int)? {
        guard let natural = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) else { return nil }
        let keySig = score.activeKey(staff: location.staff, measureIndex: location.measureIndex)
        let letterIndex = letterIndex(forTpc: natural.tpc)
        let keyAlteration = keyAlteration(forLetter: letterIndex, keySig: keySig)
        guard let nearestNatural = NoteInputPlanner.pitch(
            forLetter: letter, nearestTo: reference.map { $0 - keyAlteration },
        ) else { return nil }
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
        at location: VoiceElementID,
        in score: Score,
    ) -> (pitch: Int, tpc: Int)? {
        let crossing = score.writtenSpaceCrossing(staff: location.staff, measureIndex: location.measureIndex)
        guard !crossing.isIdentity else {
            return plannedPitch(forLetter: letter, nearestTo: concertReference, at: location, in: score)
        }
        guard let planned = plannedPitch(
            forLetter: letter,
            nearestTo: concertReference.map(crossing.writtenPitch),
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
    /// location keeps chains that span bars (`CrossBarNoteInputPlanner`) covered without special-casing them.
    public static func renotationCommands(in current: Score, changedFrom previous: Score) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        for (partIndex, part) in current.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                let before = previous[address]?.measures
                let durations = current.effectiveMeasureDurations(partIndex: partIndex, staffIndex: staffIndex)
                for (measureIndex, measure) in staff.measures.enumerated() {
                    let wasThere = before?.indices.contains(measureIndex) == true
                    guard !wasThere || before?[measureIndex] != measure,
                          durations.indices.contains(measureIndex)
                    else { continue }
                    commands.append(contentsOf: renotate(
                        measure,
                        at: address,
                        measureIndex: measureIndex,
                        keySig: current.activeKey(staff: address, measureIndex: measureIndex),
                        division: current.division,
                        measureDuration: durations[measureIndex],
                    ))
                }
            }
        }
        return commands
    }

    /// One measure's voices rewritten with the glyphs its notes actually need — one `ReplaceVoiceElements` per voice
    /// that came out different, none for the voices that didn't.
    ///
    /// Three kinds of note are read for their alteration but never rewritten, mirroring
    /// `Score.suppressingRedundantAccidentals()`'s conservatism plus MuseScore's tie rule:
    ///
    /// - a note whose written `(letter, octave, alteration)` can't be derived from its `pitch` / `tpc` — nothing
    ///   reliable can be said about it, so it also doesn't update the state;
    /// - a USER-forced accidental — a courtesy the user asked for, which is theirs to remove;
    /// - a note tied back from the previous bar — the tie already carries the alteration across the barline, and
    ///   MuseScore prints no glyph on the far side.
    private static func renotate(
        _ measure: Measure,
        at staff: StaffAddress,
        measureIndex: Int,
        keySig: Int,
        division: Int,
        measureDuration: Fraction,
    ) -> [any EditCommand] {
        var voices = measure.voices
        var state: [Line: Int] = [:]
        for ref in noteRefs(in: measure, division: division, measureDuration: measureDuration) {
            guard case let .chord(chord) = voices[ref.voiceIndex].elements[ref.elementIndex] else { continue }
            let note = chord.notes[ref.noteIndex]
            guard let written = spelling(pitch: note.pitch, tpc: note.tpc) else { continue }
            let line = Line(letter: written.letter, octave: written.octave)
            defer { state[line] = written.alteration }
            guard note.accidentalRole != .user, note.tieBack == nil else { continue }
            // A glyph already there that says more than the tpc knows (microtonal, courtesy combination) is not ours
            // to replace on tpc evidence alone.
            if let existing = note.accidental, !isStandard(existing) { continue }
            let inForce = state[line] ?? keyAlteration(forLetter: written.letter, keySig: keySig)
            let wanted: Accidental?
            if written.alteration == inForce {
                wanted = nil
            } else if let needed = glyph(forAlteration: written.alteration) {
                wanted = needed
            } else {
                // An alteration no single glyph can spell. Saying nothing beats clearing the sign it has.
                continue
            }
            guard wanted != note.accidental else { continue }
            var mutated = chord
            mutated.notes[ref.noteIndex].accidental = wanted
            mutated.notes[ref.noteIndex].accidentalBracket = wanted == nil ? .none : note.accidentalBracket
            voices[ref.voiceIndex].elements[ref.elementIndex] = .chord(mutated)
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

    /// One note of a measure, addressed across every voice and carrying the onset tick that orders it.
    private struct NoteRef {
        let tick: Int
        let voiceIndex: Int
        let elementIndex: Int
        let noteIndex: Int
    }

    /// The alteration a reader already has in force on `line` when they reach `location`: the last one written on
    /// that line earlier in the bar, or the key signature's when the bar hasn't spoken about it yet.
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
        for ref in noteRefs(in: measure, division: division, measureDuration: measureDuration) {
            guard ref.tick < cutoff else { break }
            guard case let .chord(chord) = measure.voices[ref.voiceIndex].elements[ref.elementIndex],
                  let written = spelling(
                      pitch: chord.notes[ref.noteIndex].pitch, tpc: chord.notes[ref.noteIndex].tpc,
                  ),
                  written.letter == line.letter, written.octave == line.octave
            else { continue }
            alteration = written.alteration
        }
        return alteration
    }

    /// Every note in the measure, in tick order across all voices; ties broken by voice then in-chord index so the
    /// walk is deterministic. Grace notes ride on `Chord.graceNotesBefore` / `After` rather than on the voice, so
    /// they are left out — same conservative choice ssm's suppression pass makes.
    private static func noteRefs(in measure: Measure, division: Int, measureDuration: Fraction) -> [NoteRef] {
        var refs: [NoteRef] = []
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                if case let .chord(chord) = element {
                    for noteIndex in chord.notes.indices {
                        refs.append(NoteRef(
                            tick: tick, voiceIndex: voiceIndex, elementIndex: elementIndex, noteIndex: noteIndex,
                        ))
                    }
                }
                tick += element.tickCount(division: division, in: measureDuration) ?? 0
            }
        }
        return refs.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.voiceIndex != $1.voiceIndex { return $0.voiceIndex < $1.voiceIndex }
            return $0.noteIndex < $1.noteIndex
        }
    }

    private static func tickOffset(
        in voice: Voice, before elementIndex: Int, division: Int, measureDuration: Fraction,
    ) -> Int {
        voice.elements.prefix(elementIndex).reduce(0) {
            $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0)
        }
    }

    // MARK: - Spelling

    /// TPC of each natural letter, `C D E F G A B` order.
    private static let naturalTpcByLetter = [14, 16, 18, 13, 15, 17, 19]
    /// Semitone offset of each natural letter from C, `C D E F G A B` order.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    /// Diatonic letter index (0=C … 6=B) of a TPC. `(tpc + 1) % 7` rotates the line of fifths to align with
    /// `F C G D A E B`; the table maps that rotation back to `C D E F G A B` order.
    private static func letterIndex(forTpc tpc: Int) -> Int {
        let table = [3, 0, 4, 1, 5, 2, 6]
        return table[((tpc + 1) % 7 + 7) % 7]
    }

    /// The alteration a key signature of `keySig` puts on `letter` (0=C … 6=B). Reuses `StaffStepPitch`'s in-key
    /// window so the two paths can't drift apart.
    private static func keyAlteration(forLetter letter: Int, keySig: Int) -> Int {
        let natural = naturalTpcByLetter[letter]
        return (StaffStepPitch.inKeyTpc(naturalTpc: natural, keySig: keySig) - natural) / 7
    }

    /// The WRITTEN `(letter, octave, alteration)` behind a `pitch` / `tpc` pair, or nil when the two disagree or the
    /// tpc is outside MuseScore's range (`TPC_MIN = -1` F♭♭ … `TPC_MAX = 33` B♯♯) — callers must read nil as "say
    /// nothing about this note".
    private static func spelling(pitch: Int, tpc: Int) -> (letter: Int, octave: Int, alteration: Int)? {
        guard (-1 ... 33).contains(tpc) else { return nil }
        let letter = letterIndex(forTpc: tpc)
        let alteration = (tpc - naturalTpcByLetter[letter]) / 7
        let naturalSemi = naturalSemitoneByLetter[letter]
        let expectedPitchClass = ((naturalSemi + alteration) % 12 + 12) % 12
        guard ((pitch % 12) + 12) % 12 == expectedPitchClass else { return nil }
        return (letter, (pitch - naturalSemi - alteration) / 12 - 1, alteration)
    }

    private static func glyph(forAlteration alteration: Int) -> Accidental? {
        switch alteration {
        case 0: .natural
        case 1: .sharp
        case -1: .flat
        case 2: .doubleSharp
        case -2: .doubleFlat
        case 3: .tripleSharp
        case -3: .tripleFlat
        default: nil
        }
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
