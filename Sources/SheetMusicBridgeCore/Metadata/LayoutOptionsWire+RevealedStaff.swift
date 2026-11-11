import SheetMusicCore
import SheetMusicLayout

// Beside `LayoutOptionsWire.swift` rather than in it, which sits at the file-length budget and must stay
// self-contained for the Kotlin codegen (this extension declares no wire type).

extension LayoutOptionsWire {
    /// `revealedStaff` as the engine takes it (`ScoreViewOptions.revealedStaff`); `nil` when absent or when any index
    /// is negative.
    public var revealedStaffValue: ScoreViewOptions.RevealedStaff? {
        guard let revealedStaff, revealedStaff.partIndex >= 0, revealedStaff.staffIndexInPart >= 0,
              revealedStaff.measureIndex >= 0
        else { return nil }
        return ScoreViewOptions.RevealedStaff(
            staff: StaffAddress(
                partIndex: Int(revealedStaff.partIndex), staffIndexInPart: Int(revealedStaff.staffIndexInPart),
            ),
            measureIndex: Int(revealedStaff.measureIndex),
        )
    }
}
