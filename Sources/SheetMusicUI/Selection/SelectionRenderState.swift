import CoreGraphics
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Internal rendering state computed from a public `ScoreSelection`
/// plus caller-supplied voice colors. Passed to the layer builder so
/// it can tint selected items and draw a range-box overlay.
@available(macOS 15.0, *)
struct SelectionRenderState {
    let selectedIDs: Set<ScoreItemID>
    let voiceColors: [Int: CGColor]
    let drawRangeBox: Bool
    let rangeBoxColor: CGColor

    static let defaultBoxColor = CGColor(
        red: 0.0, green: 0.45, blue: 0.95, alpha: 1.0,
    )

    static let empty = SelectionRenderState(
        selectedIDs: [],
        voiceColors: [:],
        drawRangeBox: false,
        rangeBoxColor: defaultBoxColor,
    )

    /// Selected ink color for an item of `voiceIndex`, or `nil` when
    /// the item is not selected or the caller did not supply a color
    /// for that voice.
    func color(for id: ScoreItemID, voiceIndex: Int) -> CGColor? {
        guard selectedIDs.contains(id) else { return nil }
        return voiceColors[voiceIndex]
    }

    static func make(
        selection: ScoreSelection,
        voiceColors: [Int: Color],
        score: Score,
    ) -> SelectionRenderState {
        let cgColors = voiceColors.mapValues(resolveCGColor)
        let selectedIDs = SelectionExpansion.selectedIDs(for: selection, in: score)
        let drawRangeBox: Bool
        if case .range = selection {
            drawRangeBox = true
        } else {
            drawRangeBox = false
        }
        return SelectionRenderState(
            selectedIDs: selectedIDs,
            voiceColors: cgColors,
            drawRangeBox: drawRangeBox,
            rangeBoxColor: defaultBoxColor,
        )
    }

    private static func resolveCGColor(_ color: Color) -> CGColor {
        #if os(macOS)
            return NSColor(color).cgColor
        #else
            return UIColor(color).cgColor
        #endif
    }
}
