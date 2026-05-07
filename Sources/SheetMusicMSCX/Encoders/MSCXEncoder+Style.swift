import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Build the `<Style>` block. Phase 1 emits only `<spatium>`;
    /// page-layout / chrome encoding lives in a follow-up spec.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Style",
            children: [
                XMLTreeNode(
                    name: "spatium",
                    text: String(format: "%g", spatium)
                ),
            ]
        )
    }
}
