import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Attach lyric syllables clustered below the staff to their
    /// nearest non-rest chord by x-position.
    ///
    /// Algorithm:
    /// 1. Filter `texts` to a y-band below the staff bottom (four
    ///    line-spacings deep), restricted to `pageIndex`.
    /// 2. Cluster by y (tolerance = lineSpacing) — each cluster is
    ///    one verse, ordered top-down so verse 1 sits closest to the
    ///    staff.
    /// 3. For each verse, sort syllables by x and attach each to the
    ///    nearest non-rest `RhythmElement` by x-distance.
    /// 4. Hyphen handling: a trailing `-` becomes `.begin` /
    ///    `.middle` / `.end` based on the previous syllable's
    ///    syllabic. Underscore-only tokens (`_`) extend the previous
    ///    melisma and are not attached as new syllables — actual
    ///    `ticks` melisma duration is deferred to score assembly
    ///    (Task 13).
    static func attachLyrics(
        elements: [RhythmElement],
        texts: [TextGlyph],
        staffYLines: [CGFloat],
        pageIndex: Int = 0,
    ) -> [RhythmElement] {
        guard let bottomY = staffYLines.first,
              let topY = staffYLines.last,
              bottomY < topY,
              !elements.isEmpty,
              !texts.isEmpty
        else { return elements }

        let lineSpacing = (topY - bottomY) / 4
        let candidates = filterLyricCandidates(
            texts: texts,
            bottomY: bottomY,
            lineSpacing: lineSpacing,
            pageIndex: pageIndex,
        )
        guard !candidates.isEmpty else { return elements }

        let verses = clusterByY(candidates, lineSpacing: lineSpacing)

        var out = elements
        for verseTexts in verses {
            let sorted = verseTexts.sorted { $0.origin.x < $1.origin.x }
            assignSyllables(verseTexts: sorted, into: &out)
        }
        return out
    }

    private static func filterLyricCandidates(
        texts: [TextGlyph],
        bottomY: CGFloat,
        lineSpacing: CGFloat,
        pageIndex: Int,
    ) -> [TextGlyph] {
        let lyricWindowLo = bottomY - 4 * lineSpacing
        let lyricWindowHi = bottomY
        return texts.filter { t in
            t.pageIndex == pageIndex
                && lyricWindowLo <= t.origin.y
                && t.origin.y <= lyricWindowHi
                && !t.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Cluster syllables by y, tolerance = `lineSpacing`. Sorted
    /// top-down (verse 1 = highest y in the band, closest to staff).
    private static func clusterByY(
        _ texts: [TextGlyph], lineSpacing: CGFloat,
    ) -> [[TextGlyph]] {
        let sortedByY = texts.sorted { $0.origin.y > $1.origin.y }
        var verses: [[TextGlyph]] = []
        for t in sortedByY {
            if let lastT = verses.last?.last,
               abs(lastT.origin.y - t.origin.y) < lineSpacing
            {
                verses[verses.count - 1].append(t)
            } else {
                verses.append([t])
            }
        }
        return verses
    }

    private static func assignSyllables(
        verseTexts: [TextGlyph], into elements: inout [RhythmElement],
    ) {
        var prevSyllabic: Syllabic = .single
        for t in verseTexts {
            let trimmed = t.text.trimmingCharacters(in: .whitespaces)
            // Underscore-only tokens extend previous melisma — skip.
            if trimmed == "_" { continue }

            let endsWithHyphen = trimmed.hasSuffix("-")
            let textNoHyphen = endsWithHyphen
                ? String(trimmed.dropLast())
                : trimmed
            let syllabic = nextSyllabic(
                previous: prevSyllabic,
                endsWithHyphen: endsWithHyphen,
            )

            guard let idx = nearestChordIndex(
                toX: t.origin.x, in: elements,
            ) else { continue }

            elements[idx].chord.lyrics.append(
                Lyric(text: textNoHyphen, syllabic: syllabic),
            )
            prevSyllabic = syllabic
        }
    }

    private static func nextSyllabic(
        previous: Syllabic, endsWithHyphen: Bool,
    ) -> Syllabic {
        switch (previous, endsWithHyphen) {
        case (.begin, true), (.middle, true): .middle
        case (.begin, false), (.middle, false): .end
        case (_, true): .begin
        default: .single
        }
    }

    private static func nearestChordIndex(
        toX x: CGFloat, in elements: [RhythmElement],
    ) -> Int? {
        var bestIdx: Int?
        var bestDist: CGFloat = .infinity
        for (i, e) in elements.enumerated() {
            guard !e.isRest else { continue }
            let d = abs(e.x - x)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }
}
