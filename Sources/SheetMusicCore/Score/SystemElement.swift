import SheetMusicFoundation

/// An element that conceptually applies to the whole system at a
/// given measure position, not to a particular staff or voice.
///
/// Stored on `Score.systemMeasures` indexed by measure number, so
/// hiding or filtering individual staves leaves these elements in
/// place — they survive the same way they would in MuseScore's
/// rendering even when staff 1 is hidden.
///
/// In MuseScore's `.mscx` format these are physically nested inside
/// staff 1, voice 1; the decoder lifts them onto `SystemMeasure`
/// and the encoder writes them back at the appropriate tick of
/// staff 1, voice 1 (with `<location>` shifts where the position
/// doesn't land on a chord/rest cursor).
public enum SystemElement: Sendable, Equatable {
    case tempo(Tempo)
    case rehearsalMark(RehearsalMark)
    /// Free-form text. `StaffText.isSystemText` distinguishes
    /// system-wide labels from staff-bound directives like "pizz."
    /// — the renderer uses the flag to decide vertical placement.
    /// Either way the element is stored at the system level so
    /// staff visibility changes don't drop it.
    case staffText(StaffText)
    /// Swing-rhythm directive. `Swing.isSystemText` similarly
    /// distinguishes system swing from per-staff swing.
    case swing(Swing)
    /// Mid-score instrument change. Lifted out of the voice like the
    /// text cases above; `PositionedSystemElement.originalStaff` records
    /// the staff it was written on, and every consumer keys the change
    /// on `originalStaff.partIndex` because playback scope is the PART.
    case instrumentChange(InstrumentChange)
}
