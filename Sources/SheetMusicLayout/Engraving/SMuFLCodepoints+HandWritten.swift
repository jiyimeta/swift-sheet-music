// Hand-written, not generated: GenSMuFLTables never touches this file.
// SMuFL names that Tools/smufl/glyphnames-subset.json does not carry.
import SheetMusicFoundation

extension SMuFLCodepoint {
    // MARK: - Trill line sigils

    /// `tr` — the sigil starting a `TrillType.trill` line.
    public static let ornamentTrill: UInt32 = 0xE566
    /// Sigil starting an `upprall` line.
    public static let ornamentBottomLeftConcaveStroke: UInt32 = 0xE59A
    /// Sigil starting a `downprall` line.
    public static let ornamentLeftVerticalStroke: UInt32 = 0xE594
    /// Repeating body of the `upprall` / `downprall` zig-zag line.
    public static let ornamentZigZagLineNoRightEnd: UInt32 = 0xE59D
    /// Terminating segment of the zig-zag line.
    public static let ornamentZigZagLineWithRightEnd: UInt32 = 0xE59E

    // MARK: - Octave lines

    /// `8` — used when `ottavaNumbersOnly` is on.
    public static let ottava: UInt32 = 0xE510
    /// `8va`
    public static let ottavaAlta: UInt32 = 0xE511
    /// `8vb`
    public static let ottavaBassa: UInt32 = 0xE512
    /// `15` — used when `ottavaNumbersOnly` is on.
    public static let quindicesima: UInt32 = 0xE514
    /// `15ma`
    public static let quindicesimaAlta: UInt32 = 0xE515
    /// `15mb`
    public static let quindicesimaBassa: UInt32 = 0xE516
    /// `22` — used when `ottavaNumbersOnly` is on.
    public static let ventiduesima: UInt32 = 0xE517
    /// `22ma`
    public static let ventiduesimaAlta: UInt32 = 0xE518
    /// `22mb`
    public static let ventiduesimaBassa: UInt32 = 0xE519
}
