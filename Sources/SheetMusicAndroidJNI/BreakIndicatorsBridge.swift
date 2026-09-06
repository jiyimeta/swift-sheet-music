import Foundation
import SheetMusicBridgeCore
import SheetMusicLayout

// MARK: - Break indicators (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeBreakIndicators(...)` call site: where to draw the authoring badges that
/// mark measures carrying an explicit `<LayoutBreak>`.
///
/// `LayoutOptionsWire.breakIndicatorVisibilityRaw` let a host *ask* for these; this is what answers.
/// The visibility and the break policy both come from the cached layout entry rather than from
/// parameters, so the badges can only ever describe the layout actually on screen — a badge drawn
/// from a different policy than the one that laid the score out points at a break that is not
/// happening.
///
/// Returns a `BreakIndicatorsWire` payload with positions in document millimetres. An empty *list*
/// is the normal answer for a score with no authored breaks, or with the badges turned off; empty
/// `Data` means no answer at all — unknown handle, or no cached layout — matching every other
/// geometry entry point.
public func nativeBreakIndicators(scoreHandle: Int64) -> Data {
    guard let entry = LayoutDocumentCache.entry(for: scoreHandle) else { return Data() }

    let ptToMM = 25.4 / 72.0
    let placements = BreakIndicators.placements(
        systems: entry.document.systems,
        metrics: entry.document.metrics,
        policy: entry.options.breakPolicy,
        visibility: entry.options.breakIndicatorVisibility,
    )
    return BreakIndicatorsWire(
        indicators: placements.map {
            BreakIndicatorWire(
                kind: $0.kind == .page ? 1 : 0,
                xMm: Double($0.x) * ptToMM,
                yMm: Double($0.y) * ptToMM,
            )
        },
    ).encodeToData()
}
