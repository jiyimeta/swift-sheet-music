import SheetMusicFoundation

/// Adds a note a diatonic interval above or below every chord in a range — MuseScore's Alt+1…9 (above) and
/// Shift+Alt+1…9 (below) over a range selection, as one undo step.
///
/// `steps` is the interval number with its sign: `|steps|` = 1 unison, 2 second … 8 octave, 9 ninth. Above is
/// measured from each chord's highest note, below from its lowest. Unison and octaves keep that note's spelling;
/// every other interval is spelled in the key in force (`StaffStepPitch.diatonicShift`). A pitch the chord already
/// holds — a unison always is one — is skipped, as is a result outside MIDI range; rests and percussion staves are
/// skipped too. Added notes carry no tie.
///
/// Refused as `.invalidInterval` outside ±1…±9 and as `.targetNotFound` when the range resolves to nothing.
///
/// > Note: This command is sugar over `AddNoteToChord` (× chord) bundled in a `CompositeEditCommand` by
/// > `RangeEditPlanner`. It exists to give the operation a domain-meaningful name and to own the reference-note and
/// > spelling rules; callers can equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct AddIntervalToSelection: EditCommand {
    public let range: VoiceElementRange
    public let steps: Int

    public init(over range: VoiceElementRange, steps: Int) {
        self.range = range
        self.steps = steps
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let composite = try plan(in: score) else {
            return CompositeEditCommand(commands: [], location: range.start)
        }
        return try composite.apply(to: &score)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    func plan(in score: Score) throws -> CompositeEditCommand? {
        guard (1 ... 9).contains(abs(steps)) else { throw Self.refused(.invalidInterval(steps: steps)) }
        guard !score.voiceElements(in: range).isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        return try RangeEditPlanner.plan(over: range, in: score) { target, working in
            guard RangeEditPlanner.isPitched(target.staff, in: working),
                  case let .chord(chord)? = working[target], !chord.notes.isEmpty,
                  let added = addedNote(to: chord, keySig: working.activeKey(
                      staff: target.staff, measureIndex: target.measureIndex,
                  ))
            else { return [] }
            return [AddNoteToChord(at: target, pitch: added.pitch, tpc: added.tpc, accidental: added.accidental)]
        }?.composite
    }

    /// The note the interval adds to `chord`, or `nil` when it would duplicate a pitch or leave MIDI range.
    private func addedNote(to chord: Chord, keySig: Int) -> Note? {
        let reference = steps > 0
            ? chord.notes.max { $0.pitch < $1.pitch }
            : chord.notes.min { $0.pitch < $1.pitch }
        guard let reference else { return nil }
        let lineDelta = (abs(steps) - 1) * (steps > 0 ? 1 : -1)
        let planned: (pitch: Int, tpc: Int)?
        if lineDelta % 7 == 0 {
            let pitch = reference.pitch + 12 * (lineDelta / 7)
            planned = (0 ... 127).contains(pitch) ? (pitch, reference.tpc) : nil
        } else {
            planned = StaffStepPitch.diatonicShift(from: reference, bySteps: lineDelta, keySig: keySig)
        }
        guard let planned, !chord.notes.contains(where: { $0.pitch == planned.pitch }) else { return nil }
        return Note(
            pitch: planned.pitch, tpc: planned.tpc,
            accidental: PitchSpelling.displayedAccidental(forTpc: planned.tpc, in: keySig),
        )
    }
}
