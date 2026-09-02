// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Decode rhythm for a measure. Builds chords and rests by
    /// clustering noteheads on shared stems, then assigns each beamed
    /// stem the duration implied by the beam lines crossing it
    /// (PDFImporter+Beams). Unbeamed short notes keep the flag-based
    /// path; augmentation dots apply on top of either.
    static func decodeRhythm(
        measure: ImportMeasure,
        decoded: [DecodedPitch],
        paths: [PathSegment],
        tieMarks: TieMarks = TieMarks(),
        graceSizeThreshold: CGFloat = 0,
    ) -> [RhythmElement] {
        var pitchByGlyph: [ClassifiedGlyph: DecodedPitch] = [:]
        for dp in decoded {
            pitchByGlyph[dp.glyph] = dp
        }
        let glyphs = measure.glyphs.sorted {
            $0.geometry.origin.x < $1.geometry.origin.x
        }
        // Staff space (sp), derived from this staff's five line
        // y-coordinates. Sizes the geometry side-car (noteRects /
        // onsetRect) AND the stem-attachment x-window, which is a fraction
        // of the staff space in every music font (see
        // `stemAttachWindowInSpaces`).
        let spatium = staffSpatium(measure.staffYLines)
        // Stems and beams from OTHER staves stack at the same x as this
        // staff's notes (the systems are vertically aligned), so an x-only
        // match grabs a wrong-staff stem and the beam over it never lines
        // up. Restrict both to this staff's vertical band — the staff
        // height padded by ~2 staff-heights each side, which reaches the
        // stem ends and the beam above/below them without touching the
        // neighbouring staff (~3 staff-heights away centre-to-centre).
        let yBand = staffBeamBand(measure.staffYLines)
        let stems = paths.filter {
            isStem(in: measure, $0, noteheads: glyphs, spatium: spatium)
                && segmentOverlapsBand($0, yBand)
        }
        // Beam segments overlapping this measure cell (page-filtered
        // upstream). Gate on x so a beam belonging to a neighbouring
        // measure cannot bleed in, and on the staff band so a beam over a
        // vertically-aligned staff cannot be counted here.
        let beams = paths.filter {
            $0.kind == .beam
                && measure.xRange.contains($0.rect.midX)
                && segmentOverlapsBand($0, yBand)
        }
        // Grace noteheads render through a down-scaled matrix (~70% in
        // MuseScore). Marked so they're (a) never a main-chord lead and (b)
        // never absorbed into a neighbouring main chord's cluster; they're
        // re-attached below as `graceNotesBefore` (the same representation
        // Score A uses) and so consume no voice time — keeping the main-note
        // count and following-note x-onsets aligned with A.
        let graceIndices = graceNoteheadIndices(
            glyphs: glyphs, threshold: graceSizeThreshold,
        )

        // Beam-group geometry (① + ②): per-stem beam level computed ONCE
        // over the whole measure so union-find groups and interior
        // inheritance see every stem. Keyed by the stem's index in `stems`.
        // The notehead origins identify each stem's beam-attaching end so a
        // neighbour staff's beam grazing the notehead end isn't miscounted.
        let noteheadOrigins = glyphs
            .filter { isNotehead($0.semantic) }
            .map(\.geometry.origin)
        let levelByStem = computeBeamLevels(
            stems: stems, beams: beams, noteheadOrigins: noteheadOrigins,
            spatium: spatium,
        )

        var elements: [RhythmElement] = []
        var consumed = graceIndices

        for (i, g) in glyphs.enumerated() where !consumed.contains(i) {
            switch g.semantic {
            case let .rest(dur):
                elements.append(makeRest(glyph: g, duration: dur, spatium: spatium))
                consumed.insert(i)
            case .noteheadBlack, .noteheadHalf,
                 .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                let element = assembleChord(
                    leadIndex: i,
                    glyphs: glyphs,
                    stems: stems,
                    levelByStem: levelByStem,
                    flagBand: yBand,
                    pitchByGlyph: pitchByGlyph,
                    tieMarks: tieMarks,
                    spatium: spatium,
                    consumed: &consumed,
                )
                elements.append(element)
            default:
                continue
            }
        }

        let graces = buildGraceChords(
            indices: graceIndices, glyphs: glyphs,
            pitchByGlyph: pitchByGlyph, tieMarks: tieMarks,
        )
        let sorted = elements.sorted { $0.x < $1.x }
        return attachGraces(graces, to: sorted)
    }
}

// MARK: - Cluster assembly

extension PDFImporter {
    private static func makeRest(
        glyph: ClassifiedGlyph, duration: NoteDuration, spatium: CGFloat,
    ) -> RhythmElement {
        RhythmElement(
            chord: Chord(duration: duration, notes: []),
            x: glyph.geometry.origin.x,
            y: glyph.geometry.origin.y,
            stemDirection: nil,
            beamGroup: nil,
            onsetRect: PDFGeometryRects.glyphBox(
                origin: glyph.geometry.origin,
                advance: glyph.geometry.advance,
                spatium: spatium,
                pageIndex: glyph.geometry.pageIndex,
            ),
        )
    }

    private static func assembleChord(
        leadIndex: Int,
        glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
        levelByStem: [Int: Int],
        flagBand: ClosedRange<CGFloat>?,
        pitchByGlyph: [ClassifiedGlyph: DecodedPitch],
        tieMarks: TieMarks,
        spatium: CGFloat,
        consumed: inout Set<Int>,
    ) -> RhythmElement {
        let lead = glyphs[leadIndex]
        let cluster = stemCluster(
            startingAt: leadIndex, in: glyphs, stems: stems, spatium: spatium,
        )
        consumed.formUnion(cluster.indices)
        let (notes, noteRects) = buildChordNotes(
            clusterIndices: cluster.indices, glyphs: glyphs,
            pitchByGlyph: pitchByGlyph, tieMarks: tieMarks, spatium: spatium,
        )
        let base = baseDuration(for: lead.semantic)
        // Beam lines take precedence over flags. Only black noteheads
        // (quarter base) are beamable; half / whole notes are never beamed,
        // so a spurious beam overlap can't shorten them. The level is the
        // group-aware count computed up front (① + ②): sloped-quad
        // membership + interior inheritance + owned partial stubs.
        let beamLevels: Int
        if base == .quarter, let si = cluster.stemIndex {
            // Direct index lookup — the cluster carries the exact `stems`
            // index it chose, so two stems sharing an x can't be confused
            // (an x-only reverse lookup would mis-resolve them).
            beamLevels = levelByStem[si] ?? 0
        } else {
            beamLevels = 0
        }
        let withBeamsOrFlags: NoteDuration
        let flagShortened: Bool
        if beamLevels > 0 {
            withBeamsOrFlags = durationForBeamLevels(beamLevels, base: base)
            flagShortened = false
        } else {
            withBeamsOrFlags = applyFlags(
                base: base, glyphs: glyphs, stem: cluster.stem, lead: lead,
                flagBand: flagBand, spatium: spatium,
            )
            // A flag actually fired only when the result is shorter than the
            // base — i.e. this group-size-1 note's value HINGES on a flag
            // glyph the geometry could have mis-read (the q↔8 ambiguity). An
            // unbeamed, unflagged base note (plain quarter / half / whole) is
            // high-confidence in its value and is never a repair candidate.
            flagShortened = withBeamsOrFlags != base
        }
        let withDots = applyDots(
            duration: withBeamsOrFlags, glyphs: glyphs, lead: lead,
        )
        let dir = cluster.stem.map { stem in
            stemDirection(
                of: stem,
                noteheadYs: cluster.indices.map { glyphs[$0].geometry.origin.y },
            )
        }
        return RhythmElement(
            chord: Chord(duration: withDots, notes: ChordNotes(notes)),
            x: lead.geometry.origin.x,
            y: lead.geometry.origin.y,
            stemDirection: dir,
            beamGroup: nil,
            lowConfidenceDuration: flagShortened,
            noteheadIsFilled: isFilledNotehead(lead.semantic),
            noteRects: noteRects,
            onsetRect: PDFGeometryRects.union(noteRects),
        )
    }

    /// Order a chord's noteheads by ASCENDING PITCH before they are turned
    /// into notes, so the chord's contents do not depend on the order the
    /// glyphs happened to arrive in.
    ///
    /// WHY IT MATTERS. Content-stream order carries no musical convention:
    /// measured on one real MuseScore PDF, the same document emitted
    /// `[64, 67, 71]`, `[71, 67]` and `[76, 69, 72]`. Worse, it was the only
    /// input ordering `buildScore` was sensitive to at all, so an identical
    /// glyph multiset in a different order produced a different `Score`. A
    /// raster front-end emits glyphs in scan order and can never reproduce a
    /// PDF's content-stream order, so leaving this in place would have made
    /// vector and raster imports of the same page permanently unequal.
    ///
    /// WHY ASCENDING. MuseScore keeps a chord's notes sorted that way itself
    /// (`Chord::add`, `engraving/dom/chord.cpp` — "use pitch instead, and
    /// line as a second sort criteria"), and this package's MSCX decoder
    /// preserves document order, so a `Score` parsed from a real MuseScore
    /// file already ascends. This makes the importer agree with the parser
    /// rather than inventing a third convention.
    ///
    /// WHY PITCH AND NOT GEOMETRY. Sorting by the notehead's y would be the
    /// obvious geometric key and is WRONG twice over. It is not a total
    /// order — an F natural and an F sharp share a staff line, so they share
    /// a y — and it would reorder two noteheads of the SAME pitch, which
    /// silently changes which one survives `seenPitches` below and therefore
    /// which one's tie marks the chord keeps. Sorting by `(pitch, original
    /// position)` leaves same-pitch noteheads in content-stream order, so the
    /// dedup survivor is provably the one it has always been.
    ///
    /// Noteheads with no decoded pitch are dropped here rather than sorted;
    /// the loop below skipped them anyway.
    private static func chordNoteOrder(
        clusterIndices: [Int],
        glyphs: [ClassifiedGlyph],
        pitchByGlyph: [ClassifiedGlyph: DecodedPitch],
    ) -> [Int] {
        clusterIndices.enumerated()
            .compactMap { position, idx -> (idx: Int, pitch: Int, position: Int)? in
                guard let dp = pitchByGlyph[glyphs[idx]] else { return nil }
                return (idx, dp.midi, position)
            }
            .sorted { ($0.pitch, $0.position) < ($1.pitch, $1.position) }
            .map(\.idx)
    }

    /// Build a chord's deduped notes and their geometry rects in LOCKSTEP,
    /// applying the same pitch-dedup `ChordNotes.init` would — first
    /// occurrence of a pitch wins. This keeps `noteRects[k]` aligned with the
    /// final `chord.notes[k]` (i.e. `noteIndexInChord`), which follows the
    /// deduped survivor order, NOT raw `clusterIndices`. A notehead
    /// identified as a tie endpoint stamps `tieForward` (earlier note) and /
    /// or `tieBack` (later note).
    ///
    /// The noteheads are put in ascending-pitch order first — see
    /// `chordNoteOrder`. Sorting BEFORE the loop rather than sorting `notes`
    /// afterwards is what keeps the lockstep free: `noteRects` follows along
    /// with no index remapping, so the geometry side-car's
    /// `noteIndexInChord` stays correct by construction.
    private static func buildChordNotes(
        clusterIndices: [Int],
        glyphs: [ClassifiedGlyph],
        pitchByGlyph: [ClassifiedGlyph: DecodedPitch],
        tieMarks: TieMarks,
        spatium: CGFloat,
    ) -> (notes: [Note], noteRects: [PDFElementRect]) {
        var notes: [Note] = []
        var noteRects: [PDFElementRect] = []
        var seenPitches = Set<Int>()
        let ordered = chordNoteOrder(
            clusterIndices: clusterIndices, glyphs: glyphs,
            pitchByGlyph: pitchByGlyph,
        )
        for idx in ordered {
            guard let dp = pitchByGlyph[glyphs[idx]] else { continue }
            let id = NoteheadID(glyphs[idx].geometry)
            let note = Note(
                pitch: dp.midi,
                tpc: dp.tpc,
                accidental: dp.accidental,
                tieForward: tieMarks.forward.contains(id) ? 1 : nil,
                tieBack: tieMarks.back.contains(id) ? 1 : nil,
            )
            guard seenPitches.insert(note.pitch).inserted else { continue }
            notes.append(note)
            noteRects.append(PDFGeometryRects.glyphBox(
                origin: glyphs[idx].geometry.origin,
                advance: glyphs[idx].geometry.advance,
                spatium: spatium,
                pageIndex: glyphs[idx].geometry.pageIndex,
            ))
        }
        return (notes, noteRects)
    }

    /// Staff space (sp) = one inter-line gap, derived from the staff's five
    /// line y-coordinates (`span / 4`). Falls back to a nominal 8pt when
    /// fewer than two lines were detected. Geometry-only.
    static func staffSpatium(_ yLines: [CGFloat]) -> CGFloat {
        guard let lo = yLines.min(), let hi = yLines.max(), hi > lo else {
            return 8
        }
        return (hi - lo) / 4
    }
}

// MARK: - Stem detection / clustering

extension PDFImporter {
    /// A stem is a vertical inside the measure cell that touches a
    /// notehead and is not the measure's edge barline.
    ///
    /// The earlier `lineWidth < 1` gate was tuned for a fixture whose
    /// stems were hairlines; MuseScore's real export strokes stems and
    /// barlines at the same `w` (here ~3.57pt), so a width gate either
    /// rejected every stem (observed: 0 stems → no chord clustering, no
    /// beam attachment) or admitted barlines. We instead require a
    /// notehead within `stemAttachWindow` of the vertical's x and exclude
    /// verticals sitting on the cell's left / right edge (where barlines
    /// live).
    static func isStem(
        in measure: ImportMeasure,
        _ path: PathSegment,
        noteheads: [ClassifiedGlyph],
        spatium: CGFloat,
    ) -> Bool {
        guard path.kind == .vertical,
              measure.xRange.contains(path.rect.midX)
        else { return false }
        let x = path.rect.midX
        let edgeSlop: CGFloat = 4
        let nearEdge = abs(x - measure.xRange.lowerBound) < edgeSlop
            || abs(x - measure.xRange.upperBound) < edgeSlop
        // A cell-edge vertical that spans the FULL staff line span is a
        // barline — reject it. But a bar-FINAL note's stem can also sit within
        // `edgeSlop` of the edge; such a stem spans only ~an octave and is
        // OFFSET from the staff (it does not reach both outer lines), so it is
        // kept rather than swallowed as a barline (ロビンソン 16→q at bar ends).
        if nearEdge, isFullStaffHeight(path, staffYLines: measure.staffYLines) {
            return false
        }
        // A stem abuts a notehead's right edge (stem-up) or left edge
        // (stem-down), offset by roughly the notehead width — which is a
        // fraction of the STAFF SPACE, not a fixed number of points.
        let window = stemAttachWindow(spatium: spatium)
        // A RASTER-detected vertical must also abut the notehead in Y.
        //
        // The x-only test above is a VECTOR-path assumption: MuseScore
        // strokes stems and barlines as paths and draws clefs,
        // accidentals and time signatures as glyphs, so a `.vertical`
        // that shares a notehead's x IS that note's stem. A raster
        // front-end sees only ink, and an accidental's vertical stroke
        // sits at the note's own y, inside the x-window, on the side the
        // stem-legality penalty calls legal. Admitted, it competes for
        // the notehead in `nearestStem`, and when it wins, `stemCluster`
        // ejects the mate whose stem index no longer matches the lead's —
        // splitting the chord, flipping the measure to two voices, and
        // zeroing a voice-0-aligned pitch comparison without losing a
        // single note. Measured: lowering the raster length floor to
        // admit ~6,200 real short verticals recovered the eighths exactly
        // as well as substituting the ORACLE's verticals did (990 lost vs
        // 970) and cost pitch p50 97 -> 71, with note and measure counts
        // byte-identical.
        //
        // The discriminating fact is that a notehead sits at ONE END of
        // its stem, while a glyph stroke sharing its x is centred on it.
        // Profiling every predicted vertical over 299 pages by the
        // distance from its nearer end to such a notehead:
        //
        //     threshold   real kept   false admitted
        //     0.25 sp     83.3%       2.6%
        //     0.50 sp     90.3%       13.2%
        //     0.75 sp     91.1%       54.5%
        //
        // The false population's knee is between 0.50 and 0.75 — a
        // quarter of a staff space wide — so the threshold sits at 0.50,
        // below the knee rather than on it.
        //
        // THE CONSTANT DID NOT MATCH THAT SENTENCE: it shipped at 0.25
        // while the paragraph above chose 0.50, and nothing had ever
        // measured the difference END TO END. Swept on v2-eval (32
        // scorable renders), floor held at 2.5 sp:
        //
        //     gate    pitch p50   pitch mean   dur p50   dur mean
        //     0.25    96.5        76.5         82.0      71.6
        //     0.40    100.0       76.9         82.0      72.1
        //     0.45    100.0       76.8         82.0      73.2
        //     0.50    100.0       76.8         82.0      73.2
        //     0.55    100.0       76.8         82.0      73.2
        //     0.60    99.0        76.5         80.0      72.8
        //     0.65    78.0        65.3         64.0      62.3
        //     0.75    75.0        62.9         59.0      59.4
        //     off     72.0        62.6         59.0      59.6
        //
        // The path-level knee shows up unchanged in the SCORE metric, and
        // 0.50 is the midpoint of the [0.45, 0.55] plateau rather than an
        // endpoint of it — the same reading rule the Otsu and deskew
        // maxima needed. Paired against 0.25 it is 9 renders better, 2
        // worse (worst −6), and it takes pitch p50 to the 100.0 that
        // ORACLE verticals reach.
        //
        // The LENGTH FLOOR is not a second half of this filter, which is
        // what the grid was run to find out. At gate 0.50 the floor does
        // nothing — 2.0, 2.25 and 2.5 are the same 73.2 / 76.8 to the
        // decimal, and 3.0 is slightly WORSE (73.0 / 76.6) because it
        // starts cutting real beamed stems. There is no interaction to
        // tune: the gate carries the whole separation.
        //
        // Gated on provenance, so this is unreachable on the vector path
        // and byte-identity there is a property of the code rather than a
        // measurement. Tuplet-bracket hooks, phantom verticals from thin
        // filled quads and stem fragments would all change verdict under
        // it, and each deserves its own corpus run before the gate goes.
        return noteheads.contains { g in
            guard isNoteheadSemantic(g.semantic),
                  abs(g.geometry.origin.x - x) <= window
            else { return false }
            guard path.detectedFromRaster else { return true }
            let toEnd = min(
                abs(g.geometry.origin.y - path.rect.minY),
                abs(g.geometry.origin.y - path.rect.maxY),
            )
            return toEnd <= stemHeadEndToleranceInSpaces * spatium
        }
    }

    /// How close a notehead must sit to one END of a RASTER-detected
    /// vertical for that vertical to be that note's stem, in staff
    /// spaces. See the measurement table in `isStem`.
    ///
    /// `OMR_STEM_HEAD_END_TOL_SP` overrides it for a sweep, the same way
    /// `OMR_VERTICAL_MIN_SP` overrides the length floor — see
    /// `RasterPage.sweepOverride`. This gate and that floor are the two
    /// halves of one false-positive filter, so they have to be swept as a
    /// GRID off ONE release build; a value large enough to admit every
    /// vertical (999) is how the gate is turned off for a measurement.
    static let stemHeadEndToleranceInSpaces: CGFloat =
        RasterPage.sweepOverride("OMR_STEM_HEAD_END_TOL_SP").map { CGFloat($0) } ?? 0.5

    /// Whether `path`'s y-span reaches BOTH outer staff lines (within ~1.5pt)
    /// — the signature of a barline as opposed to a note stem. With no usable
    /// staff geometry, treats a near-edge vertical as a barline (preserving
    /// the previous unconditional edge reject).
    private static func isFullStaffHeight(
        _ path: PathSegment, staffYLines: [CGFloat],
    ) -> Bool {
        guard let lo = staffYLines.min(), let hi = staffYLines.max(), hi > lo
        else { return true }
        let tol: CGFloat = 1.5
        return path.rect.minY <= lo + tol && path.rect.maxY >= hi - tol
    }

    fileprivate struct Cluster {
        var indices: [Int]
        var stem: PathSegment?
        /// Index of `stem` in the measure's `stems` array (nil when no stem).
        /// Carried so the precomputed `levelByStem` can be read directly,
        /// without an ambiguous x-only reverse lookup.
        var stemIndex: Int?
    }

    /// Half-width of the x-window in which a notehead may be a chord-mate of
    /// the cluster's lead, in STAFF SPACES.
    ///
    /// A chord's heads do NOT all share an x. Whenever two of them are a
    /// SECOND apart the engraver has to mirror one to the other side of the
    /// stem — `conflict = (std::abs(prevLine - line) < 2)` →
    /// `mirror.set_value(...)`, offset `headWidth - stemWidth`
    /// (`rendering/score/chordlayout.cpp:2368, 2404, 2733-2741`) — so a rule
    /// that demands a shared x can never join a second's two heads.
    ///
    /// The window has to sit between two measured quantities:
    ///
    ///   * the MIRROR OFFSET, `headWidth - stemWidth` — 1.2 sp on the corpus
    ///     (980 of the 1,312 same-stem candidates outside the old window);
    ///   * the MINIMUM NOTE-TO-NOTE SPACING, ~1.5 sp on a dense small-staff
    ///     score.
    ///
    /// Those two are close, and the corpus says so sharply. Admitting the
    /// 1.5 sp population as well was measured and REJECTED: it is not a
    /// wider font's mirror, it is the next note. `bacon_epi` (staff space
    /// 3.67pt, a dense engraving) took in 58 mates at 1.5 sp and lost 14
    /// metric points, while `mimicopy_ベーコンエピ` — the same music
    /// engraved at 4.96pt — took in 24 at 1.2 sp and gained 44. Both files
    /// use the same font (notehead advance 2.00 sp in each), so a real
    /// mirror cannot be 1.2 sp in one and 1.5 sp in the other.
    ///
    /// This window is only a cheap pre-filter. What actually separates a
    /// chord-mate from a second VOICE stacked at the same x (a drum crash
    /// over a kick) is the same-stem test below, not this number: over the
    /// same corpus 237,751 out-of-window candidates resolve to a different
    /// stem and stay rejected.
    static let chordMateWindowInSpaces: CGFloat = 1.35

    /// How far off the lead's x a head may sit and still count as sharing its
    /// COLUMN, in staff spaces (the old fixed 2.5pt at the corpus's most
    /// common 5pt staff space). Beyond this a head is mirrored, and the
    /// mirror rule below applies.
    static let chordColumnToleranceInSpaces: CGFloat = 0.5

    /// Smallest vertical separation, in staff spaces, that a MIRRORED head
    /// must have from the lead. Half a staff step — well under a second's
    /// 0.5 sp, well over engraving noise.
    ///
    /// WHY A MIRRORED HEAD MUST BE AT A DIFFERENT STAFF POSITION. The
    /// engraver mirrors a head across the stem to resolve a VERTICAL
    /// collision, and `conflict = (std::abs(prevLine - line) < 2)` fires for
    /// a unison (difference 0) as well as a second (difference 1). But a
    /// unison cannot survive being merged into one chord here: `ChordNotes`
    /// dedups by pitch, so folding a same-position head into the lead's
    /// chord DELETES a note. Measured on `Alive`, admitting them cost
    /// exactly the 10 notes the 10 same-position mates carried.
    static let chordMirrorMinDYInSpaces: CGFloat = 0.25

    fileprivate static func stemCluster(
        startingAt i: Int,
        in glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
        spatium: CGFloat,
    ) -> Cluster {
        let lead = glyphs[i]
        guard let chosen = nearestStem(
            toX: lead.geometry.origin.x, noteY: lead.geometry.origin.y,
            stems: stems, spatium: spatium,
        )
        else {
            return Cluster(indices: [i], stem: nil, stemIndex: nil)
        }
        var indices = [i]
        let mateWindow = chordMateWindowInSpaces * spatium
        for (j, g) in glyphs.enumerated() where j != i {
            guard isNoteheadSemantic(g.semantic) else { continue }
            // A chord's heads sit at the lead's x, or one notehead width off
            // it when the engraver had to mirror a second across the stem
            // (see `chordMateWindowInSpaces`). Measure from the lead's x (not
            // the stem midX) so a stem-down note's left-side stem doesn't
            // slide the window into the neighbour to its right.
            let dx = abs(g.geometry.origin.x - lead.geometry.origin.x)
            guard dx <= mateWindow else { continue }
            // A head OFF the lead's column is there because the engraver
            // mirrored it across the stem, which it only does to resolve a
            // vertical collision — so it must be at a different staff
            // position. A same-position (unison) head would be deleted by
            // `ChordNotes`' pitch dedup if it were folded in here.
            if dx > chordColumnToleranceInSpaces * spatium,
               abs(g.geometry.origin.y - lead.geometry.origin.y)
               < chordMirrorMinDYInSpaces * spatium { continue }
            // …but a shared x is NOT sufficient: a drum downbeat stacks two
            // VOICES at one x — a crash (stem-up) over a kick (stem-down), each
            // on its OWN stem — and the old x-only rule fused them into one
            // chord, hiding the crash onset behind the kick's lead (the 群青/
            // 君と drum loss). Admit a same-x notehead only when it attaches to
            // the SAME stem as the lead; the other splits off in assignVoices.
            // Single-voice chords share one stem (mates still cluster); a
            // notehead with no detected stem still joins.
            let gStem = nearestStem(
                toX: g.geometry.origin.x, noteY: g.geometry.origin.y,
                stems: stems, spatium: spatium,
            )
            if let gStem, gStem.index != chosen.index { continue }
            indices.append(j)
        }
        return Cluster(
            indices: indices.sorted(), stem: chosen.stem, stemIndex: chosen.index,
        )
    }

    private static func isNoteheadSemantic(_ s: SMuFLSemantic) -> Bool {
        isNotehead(s)
    }
}

// MARK: - Duration helpers

extension PDFImporter {
    private static func baseDuration(
        for sem: SMuFLSemantic,
    ) -> NoteDuration {
        switch sem {
        case .noteheadDoubleWhole, .noteheadWhole, .noteheadXWhole: .whole
        case .noteheadHalf, .noteheadXHalf: .half
        case .noteheadBlack, .noteheadXBlack: .quarter
        default: .quarter
        }
    }

    /// Subdivision level a flag glyph encodes: a combined SMuFL flag glyph
    /// carries the FULL level (flag16thUp is a single glyph meaning two
    /// halvings), so map by glyph type, not by counting glyphs.
    private static func flagLevel(_ s: SMuFLSemantic) -> Int? {
        switch s {
        case .flag8thUp, .flag8thDown: 1
        case .flag16thUp, .flag16thDown: 2
        case .flag32ndUp, .flag32ndDown: 3
        case .flag64thUp, .flag64thDown: 4
        default: nil
        }
    }

    /// Shorten `base` by the flag attached to this note's stem.
    ///
    /// MuseScore positions a flag glyph at the notehead-side stem x, offset
    /// vertically by roughly one stem length from the notehead: a stem-UP
    /// flag origin sits ~10–14pt ABOVE the notehead, a stem-DOWN flag
    /// ~14pt BELOW it (measured empirically on this corpus; tight cluster).
    /// We anchor the y-test on the NOTEHEAD, not the detected stem's end —
    /// the nearest-vertical stem match can grab a fragment that doesn't
    /// reach the flag, so a stem-end-anchored gate dropped real flags
    /// (observed: 12 eighths/measure-part mis-read as quarters in part 0).
    /// The x-gate (`< 5`pt of the stem x, well under ~10pt note spacing)
    /// keeps an adjacent note's flag from matching. A combined flag glyph
    /// carries its whole level, so we take the MAX matched level.
    /// How far, in STAFF SPACES, a flag glyph may sit from the stem's bare
    /// end (in x and in y) and still be that stem's flag.
    ///
    /// A flag attaches at the bare end of the stem — the end away from the
    /// noteheads — and MuseScore anchors the glyph exactly there. Measured
    /// over the 135-score real corpus, of the ~54,000 flag glyphs sharing a
    /// stem's x column, **53,058 sit within 0.04 sp of that end** (up-flags
    /// and down-flags alike) and the next population is **3.1 sp** away — a
    /// different note's flag in the same column. In x the own flag is within
    /// 0.1 sp and the nearest neighbour is 1.1 sp. 0.5 sp is an order of
    /// magnitude above the observed spread and well inside both gaps.
    ///
    /// This replaces a `4 ... 22` pt window measured from the LEAD NOTEHEAD,
    /// which was wrong twice over: it was a fixed number of points for a
    /// distance that scales with the staff (an engraving-correct 3.5 sp stem
    /// is 28pt at an 8pt staff space — outside the window, so the eighth read
    /// as a QUARTER), and the lead notehead is not where the flag is. On a
    /// CHORD the stem's bare end is a chord-height farther off, so a flagged
    /// chord lost its flag even at the staff size the old window was tuned
    /// for.
    static let flagAttachToleranceInSpaces: CGFloat = 0.5

    /// The same question in Y, where the answer is different — and where
    /// 0.5 sp was silently costing every 64th note its flag.
    ///
    /// The measurement above ("53,058 of ~54,000 within 0.04 sp") is a
    /// statement about the POPULATION, not about every flag: the ~940 it
    /// leaves out are the high-level flags, whose glyph origin sits well
    /// off the stem's bare end because the glyph has to reach back along
    /// the stem to hang four hooks. Measured per level on `cov_flags`
    /// (32nd + 64th) and `extz_Now_is_the_time` (8th + 16th), both at
    /// spatium 4.56pt:
    ///
    /// | flag | offset from the bare end |
    /// |---|---|
    /// | 8th | 0.18 sp |
    /// | 16th | 0.41–0.47 sp |
    /// | 32nd | 0.17–0.20 sp |
    /// | 64th | **0.94–1.17 sp** |
    ///
    /// So the offset is NOT monotonic in level — it is a property of each
    /// glyph's own anchoring — and a per-level scale would be fitting a
    /// curve to four points. What the numbers do support is a single
    /// bound: 1.5 sp sits above the largest observed own-flag offset and
    /// far below the 3.1 sp where the next population (a different note's
    /// flag in the same column) begins.
    ///
    /// Note how close 16th already was to the old 0.5: this was not a
    /// 64th-only cliff, it was a gate one hair from cutting 16ths too.
    ///
    /// X keeps the tighter 0.5 sp. It has a different neighbour distance
    /// (own 0.1 sp, nearest neighbour 1.1 sp), so widening it to 1.5 would
    /// admit the adjacent note's flag — which is exactly the flag theft
    /// the x-gate was introduced to stop.
    static let flagAttachYToleranceInSpaces: CGFloat = 1.5

    private static func applyFlags(
        base: NoteDuration,
        glyphs: [ClassifiedGlyph],
        stem: PathSegment?,
        lead: ClassifiedGlyph,
        flagBand: ClosedRange<CGFloat>?,
        spatium: CGFloat,
    ) -> NoteDuration {
        guard let stem else { return base }
        let stemX = stem.rect.midX
        let noteY = lead.geometry.origin.y
        // The stem's bare (flag-attaching) end is the one FARTHER from the
        // notehead: a stem whose bare end sits above the notehead points up
        // (takes an up-flag), one whose bare end sits below points down. A
        // flag must agree with this orientation; a neighbour's flag that lands
        // in the correct dy window but belongs to an oppositely-stemmed note
        // is rejected (the 君と kick 8→16 flag theft).
        let stemPointsUp =
            abs(stem.rect.maxY - noteY) >= abs(stem.rect.minY - noteY)
        // A flag attaches AT the stem's bare end, so that end — not the lead
        // notehead — is what a flag is matched against.
        let bareEnd = stemPointsUp ? stem.rect.maxY : stem.rect.minY
        let attachTol = flagAttachToleranceInSpaces * spatium
        let attachTolY = flagAttachYToleranceInSpaces * spatium
        var level = 0
        for g in glyphs {
            // Staff-scope the flag match: a vertically-aligned adjacent-staff
            // flag sits at the same x but outside this staff's y-band, so
            // restricting to the band stops it from being grabbed (fixes the
            // q→8 over-read).
            if let flagBand, !flagBand.contains(g.geometry.origin.y) { continue }
            // Tight x-gate: MuseScore anchors a flag glyph at its stem's x, so
            // a note's own flag sits within ~0.1 sp of the stem; the nearest
            // neighbour flag measured on the corpus is 1.1 sp away.
            guard abs(g.geometry.origin.x - stemX) <= attachTol,
                  let lvl = flagLevel(g.semantic) else { continue }
            let isUp: Bool
            switch g.semantic {
            case .flag8thUp, .flag16thUp, .flag32ndUp, .flag64thUp: isUp = true
            default: isUp = false
            }
            // Flag orientation must match the stem's pointing direction; a
            // neighbour's flag that lands at the right height but hangs off an
            // oppositely-stemmed note is rejected (the 君と kick 8→16 theft).
            guard isUp == stemPointsUp else { continue }
            // …and it must sit AT this stem's bare end — in Y with the
            // looser bound, because a 64th flag's origin legitimately
            // sits ~1 staff space back along the stem (see
            // `flagAttachYToleranceInSpaces`). The tight bound stays on X,
            // which is what keeps a neighbour's flag out.
            guard abs(g.geometry.origin.y - bareEnd) <= attachTolY else { continue }
            level = max(level, lvl)
        }
        var d = base
        for _ in 0 ..< level {
            d = halve(d)
        }
        return d
    }

    private static func halve(_ d: NoteDuration) -> NoteDuration {
        switch d {
        case .whole: .half
        case .half: .quarter
        case .quarter: .eighth
        case .eighth: .sixteenth
        case .sixteenth: .thirtySecond
        case .thirtySecond: .sixtyFourth
        case .sixtyFourth: .oneTwentyEighth
        case .oneTwentyEighth: .twoFiftySixth
        case .twoFiftySixth: .twoFiftySixth
        case .measure: .measure
        case let .fraction(f):
            .fraction(Fraction(
                numerator: f.numerator,
                denominator: f.denominator * 2,
            ))
        }
    }

    /// Which way a chord's stem points, read from the WHOLE chord.
    ///
    /// A stem attaches at one end of the chord and extends away from it, so
    /// the direction is whichever end it overshoots further: an up-stem rises
    /// past the TOP notehead, a down-stem falls past the BOTTOM one.
    ///
    /// This used to compare the stem's midpoint against one notehead — the
    /// cluster's "lead", i.e. whichever notehead the glyph array happened to
    /// present first. For a single notehead the two rules are ALGEBRAICALLY
    /// IDENTICAL (`midY > y` ⟺ `maxY - y > y - minY`), so the common case is
    /// untouched, including the tie, which both resolve to `.down`. For a
    /// chord they differ, and the old one was wrong whenever the stem's
    /// midpoint fell between two chord-mates: MuseScore sizes a stem from the
    /// FAR notehead plus about a space, so a wide chord's down-stem barely
    /// clears the near notehead and its midpoint lands above it. That read
    /// `.up`, and `voiceFor` turns `.up` into voice 1 — so the chord moved
    /// voice.
    private static func stemDirection(
        of stem: PathSegment, noteheadYs: [CGFloat],
    ) -> StemDirection {
        guard let top = noteheadYs.max(), let bottom = noteheadYs.min() else {
            return .down
        }
        return (stem.rect.maxY - top) > (bottom - stem.rect.minY) ? .up : .down
    }

    /// Farthest a dot may sit to the right of its notehead and still be that
    /// note's own, in units of the notehead's advance width.
    ///
    /// Measured over the 135-score real corpus, the dx of every dot that
    /// clears the staccato floor and the 4pt dy band:
    ///
    ///     0.8 adv   6,711     ← the note's own dot
    ///     0.9 adv  15,183
    ///     1.1 adv     162
    ///     1.2 adv   1,269
    ///     1.3 – 1.4     0     ← nothing at all
    ///     1.5 adv+    ...     ← a later note's dot, a continuum out to 45
    ///
    /// so 1.35 sits in an empty gap. The advance is the one length in scope
    /// that tracks the staff size (it measures 2.00 staff spaces on every
    /// corpus font), which is why the floor was already expressed in it.
    static let dotOwnerMaxAdvances: CGFloat = 1.35

    private static func applyDots(
        duration: NoteDuration,
        glyphs: [ClassifiedGlyph],
        lead: ClassifiedGlyph,
    ) -> NoteDuration {
        var dotCount = 0
        let leadX = lead.geometry.origin.x
        let leadY = lead.geometry.origin.y
        // Staff-size-relative floor on dx, expressed in the lead notehead's
        // own advance width — the one length in scope that tracks the staff
        // size (a medley's reduced staves engrave the same proportions at
        // ~60% of the pt distances). Measured over the curated corpus, a
        // real augmentation dot sits 0.83–1.22 advances to the RIGHT of the
        // notehead, while a STACCATO dot is centred over it at 0.23–0.25 —
        // a 3.3× gap with nothing in between. `articStaccatoAbove/Below`
        // has no Tier-1 semantic, so Tier 4 shape-matching names that
        // identical circle `augmentationDot` (131 glyphs across the corpus)
        // and only the placement can reject it.
        //
        // dy stays an absolute 4pt: the same measurement puts real dots
        // within 0.25 advances vertically and staccato at 0.40+, but
        // converting the dy bound to 0.33 advances as well cost dur% on two
        // real-corpus scores (W●RK 89→88, うちで踊ろう 93→92) — their dots
        // sit between 3pt and 4pt off on small staves. The dx floor alone
        // rejects every staccato this note owns, so the dy bound buys
        // nothing here.
        let advance = lead.geometry.advance
        let minDX = advance > 0 ? advance * 0.5 : 0
        let maxDX = advance > 0 ? advance * dotOwnerMaxAdvances : 12
        for g in glyphs {
            guard case .augmentationDot = g.semantic else { continue }
            let dx = g.geometry.origin.x - leadX
            let dy = abs(g.geometry.origin.y - leadY)
            // The ceiling is in the SAME units as the floor — see
            // `dotOwnerMaxAdvances`. It used to be a fixed 12pt, which is
            // 1.2 advances at the corpus's most common staff space but only
            // 1.0 at its largest (clipping real dots) and 2.5 at its
            // smallest (admitting a neighbour's).
            guard dx > minDX, dx < maxDX, dy < 4 else { continue }
            // A LATER note's staccato can still fall in this note's window
            // (12 of the corpus's 131, all in 君とParadiso). It belongs to
            // whichever notehead it is centred over, so hand it back.
            if isStaccatoOfSomeNotehead(g, in: glyphs) { continue }
            dotCount += 1
        }
        return dotCount > 0 ? duration.dotted(dotCount) : duration
    }

    /// Is this dot glyph really some notehead's STACCATO — i.e. centred
    /// over a notehead rather than placed to its right?
    ///
    /// Measured over the curated corpus (`dotGeometryProbe`), in units of
    /// the notehead's own advance width: a staccato sits 0.23–0.25 across
    /// and 0.40–0.67 above / below its owner, an augmentation dot 0.83–1.22
    /// across and within 0.25 vertically. The boxes are disjoint, and this
    /// test fires on 0 of the ~1080 real dots in the corpus.
    private static func isStaccatoOfSomeNotehead(
        _ dot: ClassifiedGlyph, in glyphs: [ClassifiedGlyph],
    ) -> Bool {
        for g in glyphs where isNotehead(g.semantic) {
            let advance = g.geometry.advance
            guard advance > 0 else { continue }
            let dx = (dot.geometry.origin.x - g.geometry.origin.x) / advance
            let dy = abs(dot.geometry.origin.y - g.geometry.origin.y) / advance
            if dx > 0, dx < 0.4, dy > 0.32, dy < 0.9 { return true }
        }
        return false
    }
}
