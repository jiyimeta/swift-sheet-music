import SheetMusicFoundation

/// `MeasureAccidentals` for a part some of whose chords are drawn on a sibling staff (`Chord.staffMove`).
///
/// MuseScore keeps one accidental state per staff a note is DRAWN on (`ModifyDom::cmdUpdateNotes`,
/// `rendering/score/modifydom.cpp:80-126`), so a right-hand chord moved into the bass staff reads and sets the bass
/// staff's state. These read a bar of the whole part through `MeasureAccidentalWalk.noteRefs(onVisualStaff:…)`; a part
/// with nothing moved never comes here and keeps the per-staff walk.
extension MeasureAccidentals {
    /// The notes staff `location.staff` draws in `location.measureIndex`, in the order its accidental state reads them,
    /// each with its onset tick — or nil when nothing in the part is drawn on another staff, so the caller reads the
    /// staff's own bar as it always has.
    static func drawnNotes(onStaffOf location: VoiceElementID, in score: Score) -> [(tick: Int, note: Note)]? {
        guard score.parts.indices.contains(location.staff.partIndex) else { return nil }
        let part = score.parts[location.staff.partIndex]
        guard part.hasEffectiveStaffMoves else { return nil }
        let bar = PartBar(location.measureIndex, of: part, at: location.staff.partIndex, in: score)
        return MeasureAccidentalWalk.noteRefs(
            onVisualStaff: location.staff.staffIndexInPart, of: part, measures: bar.measures,
            durations: bar.durations, division: score.division,
        ).compactMap { ref in bar.note(at: ref).map { (ref.ref.tick, $0) } }
    }

    /// `renotate` for every staff of `part` at `measureIndex` at once: each pitched staff walks the notes it draws from
    /// its own key, and every staff's voice that came out different gets one `ReplaceVoiceElements`. The rule for each
    /// note is `renotate`'s (`glyph(for:…)`).
    static func renotatePart(
        _ measureIndex: Int, of part: Part, at partIndex: Int, in score: Score,
    ) -> [any EditCommand] {
        let bar = PartBar(measureIndex, of: part, at: partIndex, in: score)
        let staves = part.staves.map(\.measures)
        let detached = DetachedTies.links(in: staves, sourceMeasures: max(measureIndex - 2, 0) ... measureIndex)
        let tieStarts = staves.indices.map { staffIndex in
            bar.measures[staffIndex] == nil ? [:] : MeasureAccidentalWalk.tieStartTPCs(
                in: staves[staffIndex], measureIndex: measureIndex,
                crossVoice: CrossVoiceTies.links(
                    in: staves[staffIndex], sourceMeasures: max(measureIndex - 1, 0) ... measureIndex,
                ),
                detached: DetachedTies.StaffEnds(staff: staffIndex, links: detached, staves: staves),
            )
        }
        var voices = bar.measures.map { $0?.voices ?? [] }
        for visualStaff in part.staves.indices where part.staves[visualStaff].group != "percussion" {
            let keySig = score.activeKey(
                staff: StaffAddress(partIndex: partIndex, staffIndexInPart: visualStaff), measureIndex: measureIndex,
            )
            var state: [Line: AccidentalLineState] = [:]
            let refs = MeasureAccidentalWalk.noteRefs(
                onVisualStaff: visualStaff, of: part, measures: bar.measures, durations: bar.durations,
                division: score.division,
            )
            for ref in refs {
                guard let note = bar.note(at: ref), let measure = bar.measures[ref.staff],
                      let written = AccidentalLineState.spelling(pitch: note.pitch, tpc: note.tpc)
                else { continue }
                let line = Line(letter: written.letter, octave: written.octave)
                let inForce = state[line]
                    ?? AccidentalLineState(alteration: keyAlteration(forLetter: written.letter, keySig: keySig))
                var drawn = note.accidental
                if let wanted = glyph(
                    for: note, alteration: written.alteration, against: inForce,
                    tiedFrom: ref.ref.mainAddress.flatMap { tieStarts[ref.staff][$0] },
                    alteredUnison: MeasureAccidentalWalk.hasAlteredUnison(at: ref.ref, in: measure.voices),
                ), wanted != note.accidental {
                    MeasureAccidentalWalk.updateNote(at: ref.ref, in: &voices[ref.staff]) {
                        $0.accidental = wanted
                        $0.accidentalBracket = wanted == nil ? .none : note.accidentalBracket
                    }
                    drawn = wanted
                }
                state[line] = inForce.after(note, alteration: written.alteration, drawsAccidental: drawn != nil)
            }
        }
        var commands: [any EditCommand] = []
        for (staffIndex, measure) in bar.measures.enumerated() {
            guard let measure else { continue }
            for voiceIndex in measure.voices.indices
                where voices[staffIndex][voiceIndex] != measure.voices[voiceIndex]
            {
                commands.append(ReplaceVoiceElements(
                    staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                    measureIndex: measureIndex,
                    voiceIndex: voiceIndex,
                    elements: voices[staffIndex][voiceIndex].elements,
                    tuplets: voices[staffIndex][voiceIndex].tuplets,
                ))
            }
        }
        return commands
    }

    /// One bar of a part: each staff's measure there (nil past a short staff's end) and its effective duration.
    private struct PartBar {
        let measures: [Measure?]
        let durations: [Fraction]

        init(_ measureIndex: Int, of part: Part, at partIndex: Int, in score: Score) {
            measures = part.staves.map {
                $0.measures.indices.contains(measureIndex) ? $0.measures[measureIndex] : nil
            }
            durations = part.staves.indices.map { staffIndex in
                let all = score.effectiveMeasureDurations(partIndex: partIndex, staffIndex: staffIndex)
                return all.indices.contains(measureIndex) ? all[measureIndex] : Fraction(numerator: 4, denominator: 4)
            }
        }

        func note(at ref: MeasureAccidentalWalk.PartNoteRef) -> Note? {
            measures[ref.staff].flatMap { MeasureAccidentalWalk.note(at: ref.ref, in: $0.voices) }
        }
    }
}
