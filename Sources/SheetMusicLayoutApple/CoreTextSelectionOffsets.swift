import CoreGraphics
import CoreText
import Foundation

/// Logical selection split at visual run boundaries. Called under the provider's CoreText lock.
enum CoreTextSelectionOffsets {
    static func fragments(in line: CTLine, range: Range<Int>) -> [ClosedRange<CGFloat>] {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        let fragments = runs.compactMap { fragment(in: $0, line: line, range: range) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for fragment in fragments {
            if let previous = merged.last, fragment.lowerBound <= previous.upperBound + 0.000001 {
                merged[merged.count - 1] = previous.lowerBound ... max(previous.upperBound, fragment.upperBound)
            } else {
                merged.append(fragment)
            }
        }
        return merged
    }

    private static func fragment(in run: CTRun, line: CTLine, range: Range<Int>) -> ClosedRange<CGFloat>? {
        let logical = CTRunGetStringRange(run)
        let lower = max(range.lowerBound, logical.location)
        let upper = min(range.upperBound, logical.location + logical.length)
        let count = CTRunGetGlyphCount(run)
        guard lower < upper, count > 0 else { return nil }
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        let left = positions.map(\.x).min() ?? 0
        let right = left + CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
        let isRTL = CTRunGetStatus(run).contains(.rightToLeft)

        func offset(at index: Int) -> CGFloat {
            // A bidi junction has two caret offsets. The run's own visual edge selects the correct affinity;
            // CTLine's primary offset may belong to the adjacent run on the opposite side of the RTL segment.
            if index == logical.location { return isRTL ? right : left }
            if index == logical.location + logical.length { return isRTL ? left : right }
            return min(max(CTLineGetOffsetForStringIndex(line, index, nil), left), right)
        }
        let start = offset(at: lower)
        let end = offset(at: upper)
        return min(start, end) ... max(start, end)
    }
}
