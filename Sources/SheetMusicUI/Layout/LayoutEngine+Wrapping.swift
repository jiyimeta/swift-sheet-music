import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// True when the measure at `idx` carries `<LayoutBreak>line`,
    /// forcing the next measure onto a new system. Looks only at
    /// staff 0 — line breaks are a document-level engraving
    /// decision, not per-staff (MuseScore stores them on
    /// `MeasureBase`, which is shared across staves). Mirrors
    /// `engraving/dom/measurebase.h::lineBreak()`.
    static func measureForcesLineBreak(
        at idx: Int, staves: [StaffContent]
    ) -> Bool {
        guard let s0 = staves.first,
              idx < s0.measures.count else { return false }
        return s0.measures[idx].lineBreak
    }

    /// Decide how many measures to put on the current system so
    /// that the span between this system and the next forced break
    /// (or score end) splits evenly. Mirrors MuseScore's
    /// "balanced wrap" heuristic — without it, sparse measures
    /// (rests, simple rhythms) get greedily packed into the first
    /// system, leaving 1 or 2 measures dangling on the last system
    /// of the span (a 6 + 2 split that fights MuseScore's preferred
    /// 4 + 4).
    ///
    /// Algorithm:
    /// 1. Find the next forced line break index (or `measureCount`
    ///    if none).
    /// 2. Count measures in the span = `endIdx − startIdx`.
    /// 3. Find the smallest `numSystems ≥ 1` such that the span
    ///    divided into `numSystems` even chunks fits in
    ///    `contentAvail`.
    /// 4. Return `⌈span / numSystems⌉` as the target measure count
    ///    for the current system.
    static func balancedMeasuresPerSystem(
        fromIndex startIdx: Int,
        measureCount: Int,
        minWidths: [CGFloat],
        firstHeaderBoost: CGFloat,
        contentAvail: CGFloat,
        staves: [StaffContent]
    ) -> Int {
        // Find the END of the current break-bounded span.
        var endIdx = measureCount
        for i in startIdx..<measureCount
            where measureForcesLineBreak(at: i, staves: staves) {
            endIdx = i + 1
            break
        }
        let span = endIdx - startIdx
        guard span > 0 else { return 1 }

        // Try increasing `numSystems` until each evenly-sized
        // chunk fits in `contentAvail`. We bias toward fewer
        // systems (more measures per system) when multiple
        // options fit, matching MuseScore's "fill the line"
        // preference.
        for numSystems in 1...span {
            let chunk = (span + numSystems - 1) / numSystems
            // Worst-case chunk width = sum of `chunk` consecutive
            // measures within the span, plus the synthesised
            // header for the first measure of the chunk.
            var maxChunkWidth: CGFloat = 0
            var i = startIdx
            while i < endIdx {
                let upper = min(i + chunk, endIdx)
                let slice = minWidths[i..<upper]
                var w: CGFloat = slice.reduce(0, +)
                if i == startIdx { w += firstHeaderBoost }
                maxChunkWidth = max(maxChunkWidth, w)
                i = upper
            }
            if maxChunkWidth <= contentAvail {
                return chunk
            }
        }
        return 1
    }
}
