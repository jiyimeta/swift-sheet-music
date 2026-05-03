import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// True when the measure at `idx` carries `<LayoutBreak>line`
    /// or `<LayoutBreak>page`, forcing the next measure onto a new
    /// system. Looks only at staff 0 — line / page breaks are a
    /// document-level engraving decision, not per-staff (MuseScore
    /// stores them on `MeasureBase`, which is shared across
    /// staves). Mirrors `engraving/dom/measurebase.h::lineBreak()`
    /// + the page-break promotion in
    /// `engraving/rendering/score/systemlayout.cpp:262` (a page
    /// break implies a system break).
    static func measureForcesLineBreak(
        at idx: Int, staves: [Staff]
    ) -> Bool {
        guard let s0 = staves.first,
              idx < s0.measures.count else { return false }
        let m = s0.measures[idx]
        return m.lineBreak || m.pageBreak
    }

    /// Dynamic part-label width = max(measured label widths) +
    /// padding. `useLong` selects long instrument names (first
    /// system) vs short names (continuation systems). Mirrors
    /// MuseScore's behaviour where the indent fits the longest
    /// label in the active system rather than a fixed value.
    ///
    /// `bracketColumnCount` widens the gutter by one `sp` per
    /// bracket column so stacked brackets have room to draw.
    /// One column ≈ sp * 1 of horizontal stride; the base inset
    /// (sp * 0.5) is the bracket-spine-to-staff distance.
    static func labelWidth(
        score: Score,
        metrics: StaffMetrics,
        useLong: Bool,
        bracketColumnCount: Int = 0
    ) -> CGFloat {
        let labels: [String] = score.parts.map { part in
            if useLong {
                part.instrument.longName
                    ?? part.trackName
                    ?? ""
            } else {
                part.instrument.shortName
                    ?? part.instrument.longName.map { String($0.prefix(3)) }
                    ?? part.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
        }
        let fontSize = metrics.sp * 2.5
        var widest: CGFloat = 0
        for text in labels where !text.isEmpty {
            widest = max(
                widest,
                LayoutEngine.lyricsTextWidth(text, sp: metrics.sp)
                    * (fontSize / (metrics.sp * 2.2))
            )
        }
        // Floor: enough room for at least 2-3 characters even if
        // every label is empty. Pad: 1 sp between text and the
        // staff so glyphs don't touch the leftmost barline.
        let pad = metrics.sp * 1
        let floor = useLong ? metrics.sp * 4 : metrics.sp * 2
        // Reserve room for bracket columns on the staff's left side.
        // One column ≈ sp * 1 of horizontal stride; the base inset
        // (sp * 0.5) is the bracket-spine-to-staff distance.
        let bracketGutter: CGFloat = bracketColumnCount > 0
            ? CGFloat(bracketColumnCount) * metrics.sp + metrics.sp * 0.5
            : 0
        return max(floor, widest + pad) + bracketGutter
    }

    /// Threshold (in measures) for switching between balanced
    /// and greedy wrap. Spans up to this size use balanced wrap
    /// (the user authored explicit breaks roughly that close
    /// together → likely they want even systems within the
    /// span). Larger spans fall back to width-greedy wrap, which
    /// is what MuseScore does for unbroken stretches —
    /// auto-balancing 60 measures into 8-per-system would over-
    /// pack measures that comfortably fit 4-per-system at
    /// natural stretch.
    static let balancedSpanLimit = 12

    /// Decide how many measures to put on the current system. For
    /// short break-bounded spans (≤ `balancedSpanLimit` measures),
    /// returns an even split so 8 measures between two breaks
    /// land as 4 + 4 instead of greedy 6 + 2. For longer spans,
    /// returns `Int.max` — letting the system packer fall back
    /// to width-only greedy wrap, matching MuseScore's behaviour
    /// for unbroken stretches.
    static func balancedMeasuresPerSystem(
        fromIndex startIdx: Int,
        measureCount: Int,
        minWidths: [CGFloat],
        firstHeaderBoost: CGFloat,
        contentAvail: CGFloat,
        staves: [Staff]
    ) -> Int {
        // Find the END of the current break-bounded span.
        var endIdx = measureCount
        for i in startIdx ..< measureCount
            where measureForcesLineBreak(at: i, staves: staves)
        {
            endIdx = i + 1
            break
        }
        let span = endIdx - startIdx
        guard span > 0 else { return Int.max }
        // Long spans → no cap, system packer goes greedy.
        if span > balancedSpanLimit { return Int.max }

        // Short span: pick smallest `numSystems` such that each
        // evenly-sized chunk fits. Biases toward fewer systems
        // (more measures per system) when multiple options fit,
        // matching MuseScore's "fill the line" preference.
        for numSystems in 1 ... span {
            let chunk = (span + numSystems - 1) / numSystems
            // Worst-case chunk width = sum of `chunk` consecutive
            // measures within the span, plus the synthesised
            // header for the first measure of the chunk.
            var maxChunkWidth: CGFloat = 0
            var i = startIdx
            while i < endIdx {
                let upper = min(i + chunk, endIdx)
                let slice = minWidths[i ..< upper]
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
