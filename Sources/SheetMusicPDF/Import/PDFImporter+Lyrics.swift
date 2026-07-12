#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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

    /// Attach a verse's per-character glyphs to notes by x-TERRITORY: each
    /// non-rest chord owns the x-interval closer to it than to its
    /// neighbours (a 1-D Voronoi cell), and every glyph inside that interval
    /// forms that chord's syllable, concatenated in x-order.
    ///
    /// This replaces an x-gap split threshold (`fontSize × 0.32`), which
    /// merged adjacent syllables in dense measures — the inter-syllable
    /// advance there falls below the threshold, so "あ·な·た·は" under four
    /// close notes collapsed to one token. Grouping against the note grid
    /// MuseScore itself centres each syllable under is spacing-independent:
    /// four syllables under four notes stay four, while a 2-glyph kana
    /// ("しゃ") or a Latin run ("birth") clustered under ONE note stays one.
    /// Repeated syllables ("woo woo woo") land on distinct notes because each
    /// glyph falls in its own note's cell. Trailing melisma underscores are
    /// stripped; an underscore-/hyphen-only cell attaches nothing; a
    /// surviving trailing hyphen marks begin / middle / end.
    private static func attachVerse(
        verseTexts: [TextGlyph], verse: Int, into elements: inout [RhythmElement],
    ) {
        let noteIdxs = elements.indices
            .filter { !elements[$0].isRest }
            .sorted { elements[$0].x < elements[$1].x }
        guard !noteIdxs.isEmpty else { return }
        let noteXs = noteIdxs.map { elements[$0].x }
        // Bucket each glyph onto the note whose x it is nearest to.
        var glyphsByNotePos: [Int: [TextGlyph]] = [:]
        for g in verseTexts {
            glyphsByNotePos[nearestNotePos(g.origin.x, noteXs), default: []].append(g)
        }
        // Ordered cells (note position ascending), each x-sorted.
        var cells = glyphsByNotePos
            .sorted { $0.key < $1.key }
            .map { (pos: $0.key, glyphs: $0.value.sorted { $0.origin.x < $1.origin.x }) }
        reglueSmallKana(&cells)
        var prevSyllabic: Syllabic = .single
        for cell in cells {
            guard let syllable = buildSyllable(cell.glyphs) else { continue }
            let syllabic = nextSyllabic(
                previous: prevSyllabic, endsWithHyphen: syllable.hyphen,
            )
            elements[noteIdxs[cell.pos]].chord.lyrics.append(
                Lyric(text: syllable.text, syllabic: syllabic, verse: verse),
            )
            prevSyllabic = syllabic
        }
    }

    /// Hiragana / katakana small (yōon / sokuon) forms and the chōonpu, which
    /// never begin a syllable — they ride on the base glyph to their left.
    private static let smallKana: Set<Character> = [
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
        "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ",
        "ー",
    ]

    /// Re-glue a leading small kana that the note-territory split severed
    /// from its base. The Voronoi bucketing assigns each glyph independently,
    /// so a small kana whose x drifts past the midpoint to the next note
    /// lands at the FRONT of that note's cell, ahead of the cell's own base
    /// ("ゃ·し" for a "…しゃ | し…" run). When a cell starts with a small kana
    /// AND still holds a following base glyph, move the leading small kana(s)
    /// back onto the previous cell. The `glyphs.count >= 2` guard is load
    /// bearing: a cell that is a small kana ALONE is a genuine mora on its own
    /// note (a melisma split such as A's "ず·っ·と") and must stay put.
    private static func reglueSmallKana(
        _ cells: inout [(pos: Int, glyphs: [TextGlyph])],
    ) {
        var glued: [(pos: Int, glyphs: [TextGlyph])] = []
        for cell in cells {
            var glyphs = cell.glyphs
            while glyphs.count >= 2, !glued.isEmpty,
                  let first = glyphs.first?.text.trimmingCharacters(in: .whitespaces).first,
                  smallKana.contains(first)
            {
                glued[glued.count - 1].glyphs.append(glyphs.removeFirst())
            }
            glued.append((cell.pos, glyphs))
        }
        cells = glued
    }

    /// Index (into the x-sorted note list) of the note nearest `x`.
    private static func nearestNotePos(_ x: CGFloat, _ noteXs: [CGFloat]) -> Int {
        var best = 0
        var bestDist = CGFloat.infinity
        for (i, nx) in noteXs.enumerated() {
            let d = abs(nx - x)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// Concatenate a note's glyphs (already x-sorted) into one syllable.
    /// Strips trailing melisma underscores and returns `nil` for an empty or
    /// underscore-/hyphen-only cell (a melisma extender attaches no
    /// syllable). A surviving trailing hyphen is reported separately and
    /// removed from the text.
    private static func buildSyllable(
        _ glyphs: [TextGlyph],
    ) -> (text: String, hyphen: Bool)? {
        var joined = glyphs
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined()
        while joined.hasSuffix("_") {
            joined.removeLast()
        }
        guard !joined.isEmpty, joined != "-" else { return nil }
        let endsWithHyphen = joined.hasSuffix("-")
        let text = endsWithHyphen ? String(joined.dropLast()) : joined
        guard !text.isEmpty else { return nil }
        return (text, endsWithHyphen)
    }

    /// A colon (ASCII `:` or full-width `：`) never appears inside a real
    /// `<Lyrics>` syllable in the corpus, but the arrangers' performance
    /// notes — MuseScore `StaffText` typed as `<label>:<instruction>`
    /// ("Lead:やりたきゃやる", "Perc.:⾳数減らしめ", "cho:…") — do, and they
    /// land in the lyric band where they masquerade as syllables and depress
    /// precision. This removes them from the page-level text pool BEFORE the
    /// per-measure lyric attachment runs: a colon glyph belongs to a staff-
    /// text run, so the whole contiguous same-line run that contains it is a
    /// staff text. It must run page-wide (not per measure) because a typed
    /// sentence spans several measures' x-cells, and a per-measure pass only
    /// sees the colon in the fragment that holds it — the continuation
    /// fragments would survive. Colon-free text (real lyrics, song-section
    /// titles) is left untouched.
    static func removeColonAnnotations(
        _ texts: [TextGlyph], lineSpacing: CGFloat,
    ) -> [TextGlyph] {
        guard texts.contains(where: hasColon), lineSpacing > 0 else { return texts }
        var kept: [TextGlyph] = []
        // Concatenate pages in ascending page order — Dictionary(grouping:)
        // iterates in hash order, which would make the kept pool's
        // cross-page ordering seed-dependent for downstream consumers.
        let byPage = Dictionary(grouping: texts, by: \.pageIndex)
        for (_, pageTexts) in byPage.sorted(by: { $0.key < $1.key }) {
            kept.append(contentsOf: dropAnnotationRuns(pageTexts, lineSpacing: lineSpacing))
        }
        return kept
    }

    private static func hasColon(_ t: TextGlyph) -> Bool {
        t.text.contains(":") || t.text.contains("：")
    }

    /// Drop, from a single page's text glyphs, every contiguous same-line
    /// prose run that contains a colon. See `removeColonAnnotations`.
    private static func dropAnnotationRuns(
        _ texts: [TextGlyph], lineSpacing: CGFloat,
    ) -> [TextGlyph] {
        guard texts.contains(where: hasColon) else { return texts }
        // Reading order: top row first (descending y), left→right within a
        // row (rows separated by > half a line-spacing).
        let sorted = texts.sorted {
            abs($0.origin.y - $1.origin.y) > lineSpacing / 2
                ? $0.origin.y > $1.origin.y
                : $0.origin.x < $1.origin.x
        }
        var keep: [TextGlyph] = []
        var run: [TextGlyph] = []
        func flush() {
            if !run.contains(where: hasColon) { keep.append(contentsOf: run) }
            run.removeAll(keepingCapacity: true)
        }
        for g in sorted {
            if let last = run.last {
                // Same text line, and within one prose advance of the previous
                // glyph: tighter than note spacing, so a real lyric row (whose
                // syllables sit a full note apart) breaks into its own runs
                // while a typed sentence stays one run.
                let sameRow = abs(last.origin.y - g.origin.y) <= lineSpacing / 2
                let advance = max(last.fontSize, g.fontSize) * 1.3
                let dx = g.origin.x - last.origin.x
                if sameRow, dx >= 0, dx <= advance {
                    run.append(g)
                    continue
                }
            }
            flush()
            run.append(g)
        }
        flush()
        return keep
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
