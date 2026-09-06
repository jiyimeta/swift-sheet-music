import SheetMusicFoundation

/// Adds a note a diatonic interval above or below every chord in a range — MuseScore's Alt+1…0 (above) and
/// Shift+Alt+2…0 (below) over a range selection, as one undo step.
///
/// `steps` is the interval number with its sign: `|steps|` = 1 unison, 2 second … 8 octave, 9 ninth, 10 tenth —
/// MuseScore's own range, where `Alt+0` is the TENTH and the octave is `Alt+8` (`shortcuts_mac.xml`). Above is
/// measured from each chord's highest note, below from its lowest. The spelling rule is
/// `IntervalPlanner.note(_:above:keySig:)`, shared with the single-note client path. A pitch the chord already
/// holds — a unison always is one — is skipped, as is a result outside MIDI range; rests and percussion staves are
/// skipped too. Added notes carry no tie.
///
/// Refused as `.invalidInterval` outside ±1…±10 and as `.targetNotFound` when the range resolves to nothing.
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
        guard (1 ... 10).contains(abs(steps)) else { throw Self.refused(.invalidInterval(steps: steps)) }
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
        // The rule itself lives in `IntervalPlanner` so that this and the single-note client path cannot drift —
        // including the octave case, which keeps the reference's own spelling instead of re-reading the key.
        let planned = IntervalPlanner.note(steps, above: reference, keySig: keySig)
        guard let planned, !chord.notes.contains(where: { $0.pitch == planned.pitch }) else { return nil }
        return Note(
            pitch: planned.pitch, tpc: planned.tpc,
            accidental: PitchSpelling.displayedAccidental(forTpc: planned.tpc, in: keySig),
        )
    }
}
