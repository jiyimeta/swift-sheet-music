#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutDocument {
    /// Measure-local x of the grace notehead `target` names, or `nil` when this measure did not lay it out.
    ///
    /// A grace note occupies its own column left (or right) of its parent chord, so the frame around it is that
    /// column — the same shape `cursorFrame(for:in:)` gives a note — rather than the parent's. That is what lets
    /// `editingCaretRect(for:in:minimumWidth:)` draw a selected grace note's caret where the grace is.
    func graceNoteX(_ target: GraceNoteID, in measure: LayoutMeasure) -> CGFloat? {
        for element in measure.elements {
            guard case let .graceChord(notes, _, _, _, _, _, _, _) = element,
                  let note = notes.first(where: { $0.graceNoteID == target })
            else { continue }
            return note.origin.x
        }
        return nil
    }
}
