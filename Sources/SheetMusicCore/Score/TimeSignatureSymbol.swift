import SheetMusicFoundation

/// How a time signature is DRAWN — as its two stacked numbers, or as one of the four symbols that stand in
/// for a particular meter. C++: `mu::engraving::TimeSigType`.
///
/// The symbol never decides how long a bar is. `TimeSignature.numerator` / `.denominator` remain the sole
/// authority for that, the same split MuseScore keeps between `TimeSig::sig()` and `TimeSig::timeSigType()`:
/// a C is 4/4 because the score also says 4/4, not because the glyph implies it. Playback, re-barring and
/// beam grouping therefore never read this property.
///
/// Each symbol has a meter it conventionally stands for (`conventionalMeter`), and a score pairing one with a
/// different meter is malformed. The parser still keeps what it read — see `TimeSignature` — while
/// `SetTimeSignature` refuses to WRITE such a pair.
///
/// The raw values are MuseScore's `<subtype>` integers and are part of the MSCX format. Never renumber them.
public enum TimeSignatureSymbol: Int, Sendable, Equatable, CaseIterable {
    /// The numerator over the denominator, in time-signature digits. MuseScore `TimeSigType::NORMAL`.
    case numeric = 0
    /// `timeSigCommon` — the C of common time. MuseScore `TimeSigType::FOUR_FOUR`.
    case common = 1
    /// `timeSigCutCommon` — the struck-through C of cut time. MuseScore `TimeSigType::ALLA_BREVE`.
    case cutCommon = 2
    /// `timeSigCut2` — Bach's cut-time sign, a slashed 2. MuseScore `TimeSigType::CUT_BACH`.
    case cutBach = 3
    /// `timeSigCut3` — cut triple time, a slashed 3. MuseScore `TimeSigType::CUT_TRIPLE`.
    case cutTriple = 4

    /// The meter this symbol stands for, or `nil` for `.numeric`, which stands for whatever it is paired with.
    ///
    /// Mirrors the meters MuseScore's time-signature palette pairs each symbol with
    /// (`TimeSig::subtypeUserName`, which names `.cutTriple` "Cut triple time (9/8)").
    public var conventionalMeter: (numerator: Int, denominator: Int)? {
        switch self {
        case .numeric: nil
        case .common: (4, 4)
        case .cutCommon, .cutBach: (2, 2)
        case .cutTriple: (9, 8)
        }
    }
}
