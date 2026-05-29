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
        switch selection {
        case .none:
            return SelectionRenderState(
                selectedIDs: [],
                voiceColors: cgColors,
                drawRangeBox: false,
                rangeBoxColor: defaultBoxColor,
            )
        case let .single(id):
            // Tuplet selection expands to the set of member IDs
            // (every note/rest the bracket spans) so the existing
            // per-element coloring path lights them up; the
            // bracket itself stays default-colored.
            let expandedIDs = Self.expand(id, in: score)
            return SelectionRenderState(
                selectedIDs: expandedIDs,
                voiceColors: cgColors,
                drawRangeBox: false,
                rangeBoxColor: defaultBoxColor,
            )
        case let .range(anchor, target):
            let ids = Set(score.items(inRangeFrom: anchor, to: target))
            return SelectionRenderState(
                selectedIDs: ids,
                voiceColors: cgColors,
                drawRangeBox: true,
                rangeBoxColor: defaultBoxColor,
            )
        case let .multi(ids):
            let expanded = ids.reduce(into: Set<ScoreItemID>()) {
                $0.formUnion(Self.expand($1, in: score))
            }
            return SelectionRenderState(
                selectedIDs: expanded,
                voiceColors: cgColors,
                drawRangeBox: false,
                rangeBoxColor: defaultBoxColor,
            )
        }
    }

    /// For non-tuplet IDs returns `[id]`; for a tuplet returns the
    /// tuplet ID itself plus every member chord/rest the bracket
    /// spans. Keeping the tuplet ID in the result lets the
    /// renderer tint the bracket / number, while the member IDs
    /// drive notehead / rest tinting through the same pipeline.
    private static func expand(
        _ id: ScoreItemID, in score: Score,
    ) -> Set<ScoreItemID> {
        guard case let .tuplet(tid) = id,
              let tuplet = score[tid],
              let staffForTuplet = score[tid.staff]
        else { return [id] }
        let measures = staffForTuplet.measures
        guard measures.indices.contains(tid.measureIndex)
        else { return [id] }
        let voices = measures[tid.measureIndex].voices
        guard voices.indices.contains(tid.voiceIndex)
        else { return [id] }
        let elements = voices[tid.voiceIndex].elements
        var out: Set<ScoreItemID> = [id]
        for j in tuplet.startIndex ... tuplet.endIndex {
            guard elements.indices.contains(j),
                  case let .chord(c) = elements[j]
            else { continue }
            if c.notes.isEmpty {
                out.insert(.rest(RestID(
                    staff: tid.staff,
                    measureIndex: tid.measureIndex,
                    voiceIndex: tid.voiceIndex,
                    elementIndex: j,
                )))
            } else {
                for ni in c.notes.indices {
                    out.insert(.note(NoteID(
                        staff: tid.staff,
                        measureIndex: tid.measureIndex,
                        voiceIndex: tid.voiceIndex,
                        elementIndex: j,
                        noteIndexInChord: ni,
                    )))
                }
            }
        }
        return out
    }

    private static func resolveCGColor(_ color: Color) -> CGColor {
        #if os(macOS)
            return NSColor(color).cgColor
        #else
            return UIColor(color).cgColor
        #endif
    }
}
