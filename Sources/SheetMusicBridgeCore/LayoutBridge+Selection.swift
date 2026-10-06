import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

/// ID matching for the selection tint threaded through `LayoutBridge.buildCommands(layout:tint:)`. Split out
/// of `LayoutBridge.swift` — already at the file-length cap — since this is pure "is this ID selected" logic,
/// no geometry.
///
/// The tint's `ids` set is expected to already be expanded (a tuplet ID plus every member note/rest its
/// bracket spans) by the caller, via `SelectionExpansion` — this file does no expansion of its own. Rederiving
/// "which IDs does a tuplet selection cover" here would be a second implementation of the rule
/// `SelectionExpansion`'s own doc comment exists to prevent.
extension LayoutBridge {
    /// `tint.argb` when `id` is one of the selected `ScoreItemID`s, `nil` otherwise — including when `tint`
    /// itself is `nil`, so a caller that always asks this function (rather than special-casing `tint == nil`)
    /// still reproduces the untinted draw program byte-for-byte.
    static func tintColor(
        for id: ScoreItemID,
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
    ) -> UInt32? {
        guard let tint, tint.ids.contains(id) else { return nil }
        return tint.argb
    }

    /// `tint.argb` when `element` is a clef or an engraved element (a signature, a barline, an articulation, a tie,
    /// a slur, a dynamic…) whose identity is selected — `.clef(anchor)` for a clef, `LayoutElement.elementItemID`
    /// for the rest, the identities `ScoreHitTester` reports a click on them as. `nil` for everything else, notes and
    /// rests included: those bracket their own commands.
    static func markTintColor(
        for element: LayoutElement,
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
    ) -> UInt32? {
        guard tint != nil else { return nil }
        if case let .clef(_, _, anchor?) = element {
            return tintColor(for: .clef(anchor), tint: tint)
        }
        return element.elementItemID.flatMap { tintColor(for: $0, tint: tint) }
    }
}
