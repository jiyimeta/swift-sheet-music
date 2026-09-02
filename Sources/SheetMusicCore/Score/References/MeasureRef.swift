import SheetMusicFoundation

/// A score-wide measure column. Measures are aligned across every staff (the invariant `Score.systemMeasures`
/// documents), so one index names the bar on every staff at once; pair it with a `StaffAddress` to reach one
/// staff's `Measure`.
///
/// Member of the closed reference family (`docs/superpowers/specs/2026-09-02-edit-command-parity-design.md` §2):
/// every score location a new `EditIntent` carries is one of these types — never a bare `Int` — so that SP0 can
/// append a stable identity to each type exactly once.
public struct MeasureRef: Hashable, Sendable {
    public var measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
    }
}
