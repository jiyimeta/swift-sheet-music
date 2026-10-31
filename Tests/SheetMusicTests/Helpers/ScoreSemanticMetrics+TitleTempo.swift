import Foundation
import SheetMusicCore

/// Title and tempo readers for the corpus harness's text rows.
extension ScoreSemanticMetrics {
    /// The first title-styled text of the title frame, trimmed; `nil` when there is none (or it is blank).
    static func titleText(_ score: Score) -> String? {
        guard let frame = score.titleFrame else { return nil }
        for text in frame.texts where text.style == .title {
            let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// NFKC with every whitespace run (newlines included) collapsed to one space, trimmed: the comparison key for
    /// "is this the same title, ignoring width forms and line breaks".
    static func normalizedTitle(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The first tempo marking in score order, as beats per minute rounded to the nearest integer.
    static func firstTempoBPM(_ score: Score) -> Int? {
        for measure in score.systemMeasures {
            for positioned in measure.elements {
                if case let .tempo(tempo) = positioned.element {
                    return Int((tempo.beatsPerSecond * 60).rounded())
                }
            }
        }
        return nil
    }
}

extension LyricPlacementCounts {
    /// Field-wise sum, for accumulating per-file counts into a sweep total.
    static func += (lhs: inout LyricPlacementCounts, rhs: LyricPlacementCounts) {
        lhs.truthChars += rhs.truthChars
        lhs.on += rhs.on
        lhs.oneOff += rhs.oneOff
        lhs.far += rhs.far
        lhs.missing += rhs.missing
        lhs.extra += rhs.extra
        lhs.edits += rhs.edits
    }
}
