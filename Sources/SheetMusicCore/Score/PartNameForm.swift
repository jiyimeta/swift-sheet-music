/// Which of a part's two names a label shows: the long name engraved at the left of the first system, or the
/// abbreviation engraved there on every system after it — MuseScore's `InstrumentNameType::LONG` / `SHORT`.
///
/// Both live on `Instrument` (`longName` / `shortName`) and `SetPartNames` writes them together; the form says
/// which of the two a reader was looking at, so a host editing them can start where the reader pointed.
public enum PartNameForm: Hashable, Sendable {
    case long
    case short
}
