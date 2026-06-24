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
    /// 3. SYLLABLE RUN-GROUPING: MuseScore's PDF export emits each
    ///    lyric character as its own text glyph (one Tj per char, like
    ///    music glyphs), so a syllable such as "woo" or "しゃ" arrives
    ///    as 2–3 separate `TextGlyph`s. Group adjacent glyphs in a
    ///    verse into syllables by NEAREST-NOTE: every char whose
    ///    nearest non-rest chord is the same chord forms one syllable,
    ///    concatenated in x-order. This uses the note grid rather than
    ///    a brittle x-gap threshold and naturally yields one syllable
    ///    per sung note, matching how A (mscz) stores one `<Lyrics>`
    ///    per chord.
    /// 4. Hyphen handling: a trailing `-` (when the syllable text is a
    ///    lone hyphen char appended to a run) marks `.begin` /
    ///    `.middle` / `.end`. Underscore-only runs extend the previous
    ///    melisma and are not attached.
    /// How many staff-line spacings (spatia) below the bottom staff line the
    /// lyric search band reaches when there is NO staff below to bound it.
    /// MuseScore engraves lyric rows ≈ 6 spatia below the bottom line (the
    /// historical `4` was too shallow — most rows fell just past it, dropping
    /// the bulk of the lyrics). When a staff below exists, `nextStaffTopY`
    /// bounds the band instead (a staff's lyrics sit entirely in the gap
    /// above the next staff), and this only caps a runaway inter-system gap.
    static let lyricBandDepthSpatia: CGFloat = 8

    static func attachLyrics(
        elements: [RhythmElement],
        texts: [TextGlyph],
        staffYLines: [CGFloat],
        pageIndex: Int = 0,
        xRange: ClosedRange<CGFloat>? = nil,
        nextStaffTopY: CGFloat? = nil,
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
            xRange: xRange,
            nextStaffTopY: nextStaffTopY,
        )
        guard !candidates.isEmpty else { return elements }

        let verses = clusterByY(candidates, lineSpacing: lineSpacing)

        var out = elements
        for (verseIndex, verseTexts) in verses.enumerated() {
            let sorted = verseTexts.sorted { $0.origin.x < $1.origin.x }
            attachVerse(verseTexts: sorted, verse: verseIndex, into: &out)
        }
        return out
    }

    /// Group a verse's per-character glyphs into syllable runs by
    /// x-adjacency, then attach each run to its nearest non-rest chord.
    ///
    /// Run split: a syllable's characters sit tightly (origin step ≈
    /// 0.1–0.15 × font size, e.g. "w·o·o" at 4–6 pt for 40 pt text); a
    /// new syllable (a new sung note) starts after a wider step. The
    /// split threshold is `fontSize × 0.32` — above the intra-syllable
    /// advance for Latin runs, while leaving mora-spaced kana
    /// (~0.25–0.3 × size, e.g. ず·っ·と) as separate syllables and keeping
    /// a small kana glued to its base (しゃ at ~0.2 ×), matching how A
    /// stores one `<Lyrics>` per sung note. An exact-duplicate run
    /// snapped onto a chord that already carries it (an over-snap
    /// artifact) is dropped.
    private static func attachVerse(
        verseTexts: [TextGlyph], verse: Int, into elements: inout [RhythmElement],
    ) {
        // Clean syllable runs (x-sorted by construction).
        var runs: [(text: String, x: CGFloat, hyphen: Bool)] = []
        for run in syllableRuns(verseTexts) {
            var joined = run.text
            while joined.hasSuffix("_") {
                joined.removeLast()
            }
            guard !joined.isEmpty, joined != "-" else { continue }
            let endsWithHyphen = joined.hasSuffix("-")
            let text = endsWithHyphen ? String(joined.dropLast()) : joined
            guard !text.isEmpty else { continue }
            runs.append((text, run.x, endsWithHyphen))
        }
        guard !runs.isEmpty else { return }
        // Non-rest chord indices in x-order. Lyrics map one-syllable-per-
        // note in reading order, so attach runs to chords sequentially
        // (each run to the nearest not-yet-used chord at/after its x).
        // This preserves legitimate repeated syllables ("woo woo woo")
        // that a nearest-only snap would collapse onto one chord.
        let noteIdxs = elements.indices
            .filter { !elements[$0].isRest }
            .sorted { elements[$0].x < elements[$1].x }
        guard !noteIdxs.isEmpty else { return }
        var prevSyllabic: Syllabic = .single
        var used = Set<Int>()
        for run in runs {
            // Nearest unused chord by x.
            var bestPos: Int?
            var bestDist = CGFloat.infinity
            for (pos, idx) in noteIdxs.enumerated() where !used.contains(pos) {
                let d = abs(elements[idx].x - run.x)
                if d < bestDist { bestDist = d; bestPos = pos }
            }
            guard let bestPos else { continue }
            used.insert(bestPos)
            let idx = noteIdxs[bestPos]
            let syllabic = nextSyllabic(
                previous: prevSyllabic, endsWithHyphen: run.hyphen,
            )
            elements[idx].chord.lyrics.append(
                Lyric(text: run.text, syllabic: syllabic, verse: verse),
            )
            prevSyllabic = syllabic
        }
    }

    /// One grouped syllable: its concatenated text and its left-edge x
    /// (used for nearest-note attachment).
    private struct SyllableRun {
        var text: String
        var x: CGFloat
    }

    /// Split an x-sorted verse glyph list into syllable runs. A run
    /// continues while the ORIGIN-to-origin x-step stays at or below the
    /// intra-syllable advance (`fontSize × 0.32`, above the ~0.1–0.15×
    /// Latin glyph advance yet below the ~0.4×+ note-to-note step); a
    /// wider step starts a new syllable. A font-size change also splits
    /// (a different lyric line / verse share a y-row only by accident).
    private static func syllableRuns(_ glyphs: [TextGlyph]) -> [SyllableRun] {
        var runs: [SyllableRun] = []
        var current = ""
        var currentX: CGFloat = 0
        var prevOriginX: CGFloat?
        var prevSize: CGFloat = 0
        for g in glyphs {
            let s = g.text.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            let threshold = g.fontSize * 0.32
            let step = prevOriginX.map { g.origin.x - $0 } ?? .infinity
            let sizeChanged = prevSize > 0 && abs(g.fontSize - prevSize) > 1
            if current.isEmpty || step > threshold || sizeChanged {
                if !current.isEmpty {
                    runs.append(SyllableRun(text: current, x: currentX))
                }
                current = s
                currentX = g.origin.x
            } else {
                current += s
            }
            prevOriginX = g.origin.x
            prevSize = g.fontSize
        }
        if !current.isEmpty {
            runs.append(SyllableRun(text: current, x: currentX))
        }
        return runs
    }

    private static func filterLyricCandidates(
        texts: [TextGlyph],
        bottomY: CGFloat,
        lineSpacing: CGFloat,
        pageIndex: Int,
        xRange: ClosedRange<CGFloat>?,
        nextStaffTopY: CGFloat?,
    ) -> [TextGlyph] {
        // The band reaches `lyricBandDepthSpatia` spatia below the bottom
        // line, but never PAST the next staff below — a staff's lyrics live
        // entirely in the gap above the staff under it, so the next staff's
        // top line is the natural floor. `max(depthFloor, nextTop)` keeps the
        // depth cap active for a large inter-system gap (don't vacuum a far
        // staff's text) while letting the next-staff bound win for normal
        // spacing. Without a staff below (lowest staff of the last system on
        // a page) the depth cap alone applies.
        let depthFloor = bottomY - Self.lyricBandDepthSpatia * lineSpacing
        let lyricWindowLo = nextStaffTopY.map { max(depthFloor, $0) } ?? depthFloor
        let lyricWindowHi = bottomY
        // Constrain to this measure's x cell (padded by half a note step)
        // so a measure only claims the lyrics under its own notes — without
        // this, every measure's nearest-note snap grabs the entire row's
        // syllables onto its edge chords (massive cross-measure bleed).
        // Constrain to this measure's x cell (padded by half a note step).
        // The cell gate is what stops every measure's sequential attach
        // from pulling in neighbouring measures' syllables — without it,
        // each edge chord vacuums up the whole row (count inflates to
        // ~830 but placement precision collapses to ~30%). With it, B
        // only claims syllables under its own notes: far higher placement
        // precision (~92%) at the cost of a more conservative count, since
        // syllables landing in inter-cell gaps are dropped.
        let xPad: CGFloat = 6
        let xLo = xRange.map { $0.lowerBound - xPad } ?? -.infinity
        let xHi = xRange.map { $0.upperBound + xPad } ?? .infinity
        return texts.filter { t in
            t.pageIndex == pageIndex
                && lyricWindowLo <= t.origin.y
                && t.origin.y <= lyricWindowHi
                && t.origin.x >= xLo
                && t.origin.x <= xHi
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
}
