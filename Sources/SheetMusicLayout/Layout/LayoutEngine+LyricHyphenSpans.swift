#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Hyphen trails that cross a barline, and the two half-trails a system break leaves behind.
///
/// `placeMeasureElements` emits a hyphen when the SECOND syllable of a word arrives, looking backwards at a
/// trail it keeps per voice and verse — and that trail is declared inside a per-measure pass, so it resets at
/// every barline. Real lyrics cross barlines constantly ("glo-" on the last beat of a bar, "ri" on the next
/// bar's downbeat), and every one of those words silently lost its hyphen.
///
/// ## Why this is a system pass and not a bigger trail
///
/// MuseScore does not keep a trail at all: a hyphen is a `LyricsLine` SPANNER from the syllable to the next
/// syllable in the same verse (`LyricsLayout::createOrRemoveLyricsLine`, `findNextLyrics`), and a spanner is
/// broken into one `LyricsLineSegment` per SYSTEM. Everything that makes hyphens look right falls out of that:
/// the dash count is computed over the whole segment, so one barline crossing inside a system gets ONE dash
/// spanning the barline rather than a dash on each side of it. A per-measure emission cannot produce that, and
/// a doubled hyphen at every barline would be a worse bug than the missing one.
///
/// So this runs where a system's measures are all in hand and their x offsets are known, and computes each
/// span once, in system coordinates, before splitting the resulting dashes back into the measures they land
/// in. It is additive: a pair of syllables in the SAME measure is still emitted by `placeMeasureElements`,
/// which already gets that case right, and is skipped here.
extension LayoutEngine {
    /// One engraved syllable, as this pass needs it.
    private struct HyphenSyllable {
        /// Index into the system's `untranslated` array — not a score measure index.
        let slot: Int
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int
        let verse: Int
        /// Center x in SYSTEM coordinates (`xOffsets[slot]` already added).
        let centerX: CGFloat
        let width: CGFloat
        let y: CGFloat
        let syllabic: Syllabic
        let placement: TextPlacementMetadata
    }

    /// Which voice and verse a trail belongs to. A hyphen never crosses either.
    private struct HyphenLane: Hashable {
        let voiceIndex: Int
        let verse: Int
    }

    /// Emit every hyphen span this system owns that `placeMeasureElements` could not: one that crosses a
    /// barline inside the system, one that runs off the system's right edge, and one that arrives at its left.
    ///
    /// Runs AFTER the system-wide lyric-Y alignment — the dashes take the aligned row's y, which the two
    /// endpoints then agree on — and BEFORE the skyline autoplace pass, so a cross-measure dash is moved by
    /// the same rules as a within-measure one.
    ///
    /// Hidden syllables are invisible to this pass. They are routed to `perStaffInvisibleElements`, which is
    /// deliberately not read here, so a word whose middle syllable is hidden keeps its within-measure hyphens
    /// (placement's trail does record hidden syllables) and loses only the cross-measure one. That is the
    /// existing asymmetry, not a new one.
    static func emitCrossMeasureLyricHyphens(
        into untranslated: inout [UntranslatedMeasure],
        staffCount: Int,
        score: Score,
        xOffsets: [CGFloat],
        metrics: StaffMetrics,
    ) {
        guard !untranslated.isEmpty, xOffsets.count == untranslated.count else { return }
        let leadingStartX = systemLeadingDashX(
            untranslated: untranslated, xOffsets: xOffsets, metrics: metrics,
        )
        let trailingEndX = systemTrailingDashX(
            untranslated: untranslated, xOffsets: xOffsets, metrics: metrics,
        )
        for staffIdx in 0 ..< staffCount {
            let lanes = collectSyllables(
                in: untranslated, staffIdx: staffIdx, score: score,
                xOffsets: xOffsets, metrics: metrics,
            )
            for (_, syllables) in lanes {
                var dashes: [LayoutElement] = []
                appendCrossBarlineSpans(in: syllables, metrics: metrics, into: &dashes)
                appendSystemEdgeSpans(
                    in: syllables, score: score, staffIdx: staffIdx,
                    leadingStartX: leadingStartX, trailingEndX: trailingEndX,
                    metrics: metrics, into: &dashes,
                )
                fileDashes(
                    dashes, into: &untranslated, staffIdx: staffIdx, xOffsets: xOffsets,
                )
            }
        }
    }

    // MARK: - Gathering

    /// Every engraved syllable in this system's measures for `staffIdx`, grouped by voice + verse and ordered
    /// by musical position.
    ///
    /// The syllabic comes from the SCORE, read back through the anchor the layout element carries, because the
    /// element itself does not record it — a mark prints its text, not its word-continuation state. Ordering
    /// is `(measureIndex, elementIndex)` rather than x, so a document laid out with an unwound repeat cannot
    /// hand this pass a pair in the wrong order.
    private static func collectSyllables(
        in untranslated: [UntranslatedMeasure],
        staffIdx: Int,
        score: Score,
        xOffsets: [CGFloat],
        metrics: StaffMetrics,
    ) -> [HyphenLane: [HyphenSyllable]] {
        var lanes: [HyphenLane: [HyphenSyllable]] = [:]
        for (slot, measure) in untranslated.enumerated() {
            guard let elements = measure.perStaffElements[staffIdx] else { continue }
            for element in elements {
                guard case let .textMark(.lyrics(_, verse, anchor, placement), text, origin) = element,
                      let anchor, !text.isEmpty,
                      let syllabic = syllabic(of: anchor, verse: verse, in: score)
                else { continue }
                let resolved = placement ?? TextPlacementMetadata(side: .below, verse: verse)
                lanes[
                    HyphenLane(voiceIndex: anchor.voiceIndex, verse: verse),
                    default: [],
                ].append(HyphenSyllable(
                    slot: slot,
                    measureIndex: anchor.measureIndex,
                    voiceIndex: anchor.voiceIndex,
                    elementIndex: anchor.elementIndex,
                    verse: verse,
                    centerX: xOffsets[slot] + origin.x,
                    width: lyricsTextWidth(text, sp: metrics.sp),
                    y: origin.y,
                    syllabic: syllabic,
                    placement: resolved,
                ))
            }
        }
        return lanes.mapValues { syllables in
            syllables.sorted {
                ($0.measureIndex, $0.elementIndex) < ($1.measureIndex, $1.elementIndex)
            }
        }
    }

    /// The word-continuation state of the syllable `anchor` names in `verse`, or `nil` when the anchor names
    /// no chord, the verse is absent, or its text is empty.
    private static func syllabic(
        of anchor: VoiceElementID, verse: Int, in score: Score,
    ) -> Syllabic? {
        guard case let .chord(chord)? = score[anchor],
              chord.lyrics.indices.contains(verse)
        else { return nil }
        let lyric = chord.lyrics[verse]
        return lyric.text.isEmpty ? nil : lyric.syllabic
    }

    // MARK: - The three kinds of span

    /// Consecutive connected syllables in DIFFERENT measures of this system. A same-measure pair is left to
    /// `placeMeasureElements`, which already emitted it.
    private static func appendCrossBarlineSpans(
        in syllables: [HyphenSyllable],
        metrics: StaffMetrics,
        into dashes: inout [LayoutElement],
    ) {
        for (prev, curr) in zip(syllables, syllables.dropFirst())
            where prev.measureIndex != curr.measureIndex
            && prev.placement.side == curr.placement.side
            && connectsWithHyphen(prev: prev.syllabic, curr: curr.syllabic)
        {
            emitSpan(
                fromX: rightEdge(of: prev, sp: metrics.sp),
                toX: leftEdge(of: curr, sp: metrics.sp),
                y: prev.y, placement: prev.placement, metrics: metrics, into: &dashes,
            )
        }
    }

    /// The two halves a system break leaves: a trail running off the right edge of this system, and one
    /// arriving at its left edge.
    ///
    /// This is what MuseScore's spanner does for free. `LyricsLayout::lyricsLineEndX` sends a segment that
    /// does not end on this system to `System::endingXForOpenEndedLines()`, and `lyricsLineStartX` starts a
    /// segment that did not begin on it at `System::firstNoteRestSegmentX()` — so a word broken across a
    /// system break shows dashes at the end of one system AND at the start of the next.
    ///
    /// Only the first and last syllable of the lane can be involved: any other one has its partner inside
    /// this system, where `appendCrossBarlineSpans` or `placeMeasureElements` handled it.
    private static func appendSystemEdgeSpans(
        in syllables: [HyphenSyllable],
        score: Score,
        staffIdx: Int,
        leadingStartX: CGFloat,
        trailingEndX: CGFloat,
        metrics: StaffMetrics,
        into dashes: inout [LayoutElement],
    ) {
        guard let first = syllables.first, let last = syllables.last else { return }
        if first.syllabic == .middle || first.syllabic == .end,
           let previous = connectingNeighbour(
               of: first, direction: .backward, score: score, staffIdx: staffIdx,
           )
        {
            emitSpan(
                fromX: leadingStartX, toX: leftEdge(of: first, sp: metrics.sp),
                y: first.y, placement: TextPlacementMetadata(
                    side: first.placement.side, autoplace: previous.elementProperties.autoplace ?? true,
                    verse: first.verse, staff: first.placement.staff,
                ), metrics: metrics, into: &dashes,
            )
        }
        if last.syllabic == .begin || last.syllabic == .middle,
           connectingNeighbour(
               of: last, direction: .forward, score: score, staffIdx: staffIdx,
           ) != nil
        {
            emitSpan(
                fromX: rightEdge(of: last, sp: metrics.sp), toX: trailingEndX,
                y: last.y, placement: last.placement, metrics: metrics, into: &dashes,
            )
        }
    }

    private enum HyphenSearchDirection {
        case forward
        case backward
    }

    /// Whether the syllable next to `syllable` in its own voice and verse — the one this system does not
    /// contain — continues the same word.
    ///
    /// Walks the score's measures outward from the syllable's own, in its own voice, and stops at the FIRST
    /// syllable it finds in that verse: a word's neighbour is the next syllable, not the next connecting one,
    /// so a `.single` in between correctly answers "no".
    private static func connectingNeighbour(
        of syllable: HyphenSyllable,
        direction: HyphenSearchDirection,
        score: Score,
        staffIdx: Int,
    ) -> Lyric? {
        let entries = score.allStaves
        guard entries.indices.contains(staffIdx) else { return nil }
        let measures = entries[staffIdx].staff.measures
        guard measures.indices.contains(syllable.measureIndex) else { return nil }
        let measureOrder: [Int] = direction == .forward
            ? Array(syllable.measureIndex ..< measures.count)
            : Array((0 ... syllable.measureIndex).reversed())
        for measureIndex in measureOrder {
            let measure = measures[measureIndex]
            guard measure.voices.indices.contains(syllable.voiceIndex) else { continue }
            let elements = measure.voices[syllable.voiceIndex].elements
            var order = Array(elements.indices)
            if direction == .backward { order.reverse() }
            for elementIndex in order {
                if measureIndex == syllable.measureIndex {
                    let isPast = direction == .forward
                        ? elementIndex <= syllable.elementIndex
                        : elementIndex >= syllable.elementIndex
                    if isPast { continue }
                }
                guard case let .chord(chord) = elements[elementIndex],
                      chord.lyrics.indices.contains(syllable.verse)
                else { continue }
                let neighbour = chord.lyrics[syllable.verse]
                guard !neighbour.text.isEmpty else { continue }
                guard score.style.textPlacement.side(for: .lyrics, element: neighbour.elementProperties) == syllable
                    .placement.side else { return nil }
                let connected = direction == .forward
                    ? connectsWithHyphen(prev: syllable.syllabic, curr: neighbour.syllabic)
                    : connectsWithHyphen(prev: neighbour.syllabic, curr: syllable.syllabic)
                return connected ? neighbour : nil
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// Where a dash trail leaving a syllable starts: its right ink edge plus the same 0.3 sp pad
    /// `placeMeasureElements` uses, so a cross-measure hyphen is spaced like a within-measure one.
    private static func rightEdge(of syllable: HyphenSyllable, sp: CGFloat) -> CGFloat {
        syllable.centerX + syllable.width / 2 + sp * 0.3
    }

    private static func leftEdge(of syllable: HyphenSyllable, sp: CGFloat) -> CGFloat {
        syllable.centerX - syllable.width / 2 - sp * 0.3
    }

    /// Where a dash arriving from the previous system starts, in system coordinates.
    ///
    /// MuseScore's `System::firstNoteRestSegmentX(leading: true)` — the first note or rest of the system's
    /// first measure, backed off by the leading space, which is what keeps the dash clear of a clef / key /
    /// time redraw without needing to measure the header. `tickCols` is that measure's own event columns, so
    /// its minimum IS the first note-rest x; one notehead's worth of back-off approximates the leading space.
    ///
    /// The exact value rarely decides anything, because the target syllable usually sits ON that first column
    /// and the span comes out shorter than one dash. `emitSpan`'s minimum-length clamp then takes over, which
    /// is MuseScore's own answer to the same geometry.
    private static func systemLeadingDashX(
        untranslated: [UntranslatedMeasure], xOffsets: [CGFloat], metrics: StaffMetrics,
    ) -> CGFloat {
        let firstColumn = untranslated[0].tickCols.values.min() ?? metrics.sp * 2
        return xOffsets[0] + max(metrics.sp * 0.5, firstColumn - metrics.sp * 1.2)
    }

    /// Where a dash leaving for the next system ends: MuseScore's `System::endingXForOpenEndedLines()`, the
    /// last measure's content edge held off the barline — the same `sp` clearance `emitMelismaLine` leaves.
    private static func systemTrailingDashX(
        untranslated: [UntranslatedMeasure], xOffsets: [CGFloat], metrics: StaffMetrics,
    ) -> CGFloat {
        let lastIndex = untranslated.count - 1
        return xOffsets[lastIndex] + untranslated[lastIndex].contentWidth - metrics.sp
    }

    /// One span's worth of dashes, in system coordinates.
    ///
    /// The dash count and spacing are `emitLyricHyphens`'s — the existing port of
    /// `LyricsLayout::layoutDashes`, unchanged, so a wide gap gets several evenly spread dashes here exactly
    /// as it does inside a measure. What this adds is MuseScore's minimum-length clamp
    /// (`lyricsDashMinLength = 0.4 sp`): where the geometry leaves less room than one dash, the span is
    /// widened backwards rather than dropped. Without it the arriving half of a system-break hyphen would
    /// almost never draw, because the syllable it points at sits on the system's first column.
    private static func emitSpan(
        fromX: CGFloat, toX: CGFloat, y: CGFloat, placement: TextPlacementMetadata, metrics: StaffMetrics,
        into dashes: inout [LayoutElement],
    ) {
        let minLength = metrics.sp * 0.4
        let start = min(fromX, toX - minLength)
        guard toX > start else { return }
        var emitted: [LayoutElement] = []
        emitLyricHyphens(
            fromX: start, toX: toX, y: y, placement: placement, metrics: metrics, out: &emitted,
        )
        dashes.append(contentsOf: emitted)
    }

    // MARK: - Filing

    /// Put each dash into the measure its center lands in, converting system x back to measure-local x.
    ///
    /// A dash is 0.6 sp wide and a span's dashes are spread over the whole gap, so one can straddle a
    /// barline; its center decides which measure owns it, and the small overhang is invisible because
    /// measures are drawn contiguously.
    private static func fileDashes(
        _ dashes: [LayoutElement],
        into untranslated: inout [UntranslatedMeasure],
        staffIdx: Int,
        xOffsets: [CGFloat],
    ) {
        for element in dashes {
            guard case let .lyricHyphen(from, to, placement) = element else { continue }
            let centerX = (from.x + to.x) / 2
            var slot = 0
            for (index, offset) in xOffsets.enumerated() where offset <= centerX {
                slot = index
            }
            guard untranslated[slot].perStaffElements[staffIdx] != nil else { continue }
            let dx = xOffsets[slot]
            untranslated[slot].perStaffElements[staffIdx]?.append(.lyricHyphen(
                fromOrigin: CGPoint(x: from.x - dx, y: from.y),
                toOrigin: CGPoint(x: to.x - dx, y: to.y),
                placement: placement,
            ))
        }
    }
}
