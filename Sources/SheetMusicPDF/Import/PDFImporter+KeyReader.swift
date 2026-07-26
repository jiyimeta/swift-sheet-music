#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Key-signature reading. A key signature is the leading run of same-type
/// accidental glyphs at the canonical staff positions for the clef;
/// structural ladder matching (not note proximity) separates it from a
/// local accidental on the first melodic note. Split out of
/// PDFImporter+ScoreState.swift to keep each file within the length cap.
extension PDFImporter {
    // MARK: - Key signature

    /// Canonical key-signature accidental ladder for a **treble (G)** staff,
    /// expressed as `stepsAbove` the bottom staff line (0 = bottom line).
    /// Sharps engrave in the order F,C,G,D,A,E,B; flats in B,E,A,D,G,C,F.
    /// (Treble bottom line = E = diatonic step 2.)
    ///
    /// For any other clef family the whole ladder shifts by
    /// `(2 - bottomStep)`: a bass staff (bottom G, step 4) shifts every
    /// position **down by 2**, an alto C staff (bottom F, step 3) by 1. The
    /// shift is confirmed empirically on the corpus (G / G8vb: shift 0; F: −2,
    /// e.g. 地球儀 p5 flats at sa 2,5 and カゲロウ p6 flats at sa 2,5,1).
    private static let trebleSharpLadder = [8, 5, 9, 6, 3, 7, 4]
    private static let trebleFlatLadder = [4, 7, 3, 6, 2, 5, 1]

    /// Read the leading key signature, if any, by **structural block
    /// recognition** against the per-clef canonical accidental ladder.
    ///
    /// A real key signature is the x-leading run of same-type accidentals
    /// whose staff positions (`stepsAbove` the bottom line) match the clef's
    /// canonical ladder prefix, packed x-cohesively (~one line-spacing apart).
    /// Matching by ladder position — not by "is this accidental near a note?"
    /// — fixes two failure modes of the old proximity heuristic on dense
    /// staves (half-step ≈ 1.7pt):
    /// - **K-a (absolute-tolerance bleed)**: the block's last accidental sat a
    ///   full diatonic step from the first note yet within the old fixed
    ///   `dy ≤ 2pt` gate, so it was wrongly treated as that note's local
    ///   accidental and dropped from the key (君と −4→−3, カゲロウ p6 −3→−2).
    /// - **K-b (block accidental pairing the first note)**: a melody opening
    ///   ON a key-signature pitch put the block's last accidental at the
    ///   note's exact y, so the old heuristic paired it away (地球儀 −2→−1).
    ///
    /// The ladder is octave-independent (positions are relative to the bottom
    /// line), so it needs only the clef **family** — supplied via the staff
    /// anchor's `bottomStep`. When no anchor is available (degenerate staff
    /// lines) it falls back to the legacy proximity reader.
    ///
    /// `runningKey` is the key currently in force. When the leading region
    /// carries a NEW sharp/flat block it wins outright (the block gives the
    /// signature, and any leading naturals ahead of it are just the outgoing
    /// key's cancellation). When there is NO sharp/flat block, a leading
    /// naturals block that cancels the running key is a change TO C MAJOR —
    /// `readNaturalsCancellation` recognizes it (see there for why this is
    /// the only naturals case the block path can't already handle).
    static func readKey(
        sorted: [ClassifiedGlyph], clef: Clef, yLines: [CGFloat],
        runningKey: KeySignature,
    ) -> KeySignature? {
        guard let anchor = staffAnchor(clef: clef, yLines: yLines),
              anchor.lineSpacing > 0
        else { return readKeyLegacy(sorted: sorted) }
        let halfStep = anchor.lineSpacing / 2

        // Gather the leading accidentals up to (but not including) the first
        // notehead: a notehead ends the leading region — anything after it is
        // melodic, not part of the key signature.
        var sharpAccs: [(index: Int, sa: Int, x: CGFloat)] = []
        var flatAccs: [(index: Int, sa: Int, x: CGFloat)] = []
        var naturalAccs: [(index: Int, sa: Int, x: CGFloat)] = []
        for (i, g) in sorted.enumerated() {
            if isNotehead(g.semantic) { break }
            guard let alt = accidentalAlteration(g.semantic) else { continue }
            let sa = Int(((g.geometry.origin.y - anchor.bottomY) / halfStep).rounded())
            if alt > 0 {
                sharpAccs.append((i, sa, g.geometry.origin.x))
            } else if alt < 0 {
                flatAccs.append((i, sa, g.geometry.origin.x))
            } else {
                naturalAccs.append((i, sa, g.geometry.origin.x))
            }
        }

        let shift = 2 - anchor.bottomStep
        let sharpN = ladderPrefixCount(
            sharpAccs.map { (sa: $0.sa, x: $0.x) },
            ladder: trebleSharpLadder.map { $0 + shift },
            lineSpacing: anchor.lineSpacing,
        )
        let flatN = ladderPrefixCount(
            flatAccs.map { (sa: $0.sa, x: $0.x) },
            ladder: trebleFlatLadder.map { $0 + shift },
            lineSpacing: anchor.lineSpacing,
        )
        // No new sharp/flat block: the only remaining key event is a
        // naturals-only cancellation of the running key to C major.
        guard max(sharpN, flatN) > 0 else {
            return readNaturalsCancellation(
                naturalAccs: naturalAccs, runningKey: runningKey,
                anchor: anchor, sorted: sorted,
            )
        }

        // Safety valve — a **single** ladder[0]-aligned accidental that also
        // HUGS the following notehead (same staff line, immediately left) is a
        // local accidental on the first note, not a one-accidental key. This
        // is exactly the guard that kept a measure opening on a flatted /
        // sharped melodic note from reading as a spurious ±1 key (the Gibbs
        // 25-measure regression). Longer runs are unambiguously key blocks — a
        // melody never opens on two same-type accidentals both on ladder
        // positions — so the valve is scoped to count == 1.
        if max(sharpN, flatN) == 1 {
            let only = sharpN == 1 ? sharpAccs[0] : flatAccs[0]
            if pairsWithFollowingNotehead(at: only.index, in: sorted) {
                return nil
            }
        }
        return sharpN >= flatN
            ? KeySignature(concertKey: sharpN)
            : KeySignature(concertKey: -flatN)
    }

    /// A mid-score key change to a signature with FEWER accidentals is
    /// engraved as a **naturals-only cancellation** — one ♮ at each of the
    /// outgoing key's canonical ladder positions, with no new sharps/flats
    /// following. `readKey`'s sharp/flat-block path already reads every OTHER
    /// naturals case correctly (a change to another sharp/flat key shows the
    /// new block, which the block path counts and returns — the leading
    /// naturals are ignored harmlessly). The ONE case it can't see is the
    /// change to C major, where nothing but naturals is drawn: the block
    /// path finds `sharpN == flatN == 0` and would return nil, leaving the
    /// outgoing key wrongly in force (チャンカパーナ 3♯→C at m66; SHINY_DAYS
    /// 3♯→C at m8). MuseScore cancels EXACTLY the running key's accidentals,
    /// so a naturals block matching the running key's full ladder (`n ==
    /// |runningKey|`), x-cohesive, is that change → C major.
    ///
    /// Guards mirror the block reader: no running accidentals to cancel ⇒
    /// nothing to do; and a lone natural (running key ±1) that HUGS the
    /// following note is a local accidental, not a cancellation.
    private static func readNaturalsCancellation(
        naturalAccs: [(index: Int, sa: Int, x: CGFloat)],
        runningKey: KeySignature, anchor: StaffAnchor,
        sorted: [ClassifiedGlyph],
    ) -> KeySignature? {
        let outgoing = runningKey.concertKey
        guard outgoing != 0, !naturalAccs.isEmpty else { return nil }
        let shift = 2 - anchor.bottomStep
        let ladder = (outgoing > 0 ? trebleSharpLadder : trebleFlatLadder)
            .map { $0 + shift }
        let n = ladderPrefixCount(
            naturalAccs.map { (sa: $0.sa, x: $0.x) },
            ladder: ladder, lineSpacing: anchor.lineSpacing,
        )
        // A naturals-only cancellation cancels the WHOLE running key — a
        // partial naturals block would leave residual accidentals that are
        // shown as sharps/flats (handled by the block path), never as bare
        // naturals. Requiring the full count also makes a stray single
        // courtesy natural (which only reaches count 1 when |runningKey|==1)
        // fall to the hug guard below rather than firing spuriously.
        guard n == abs(outgoing) else { return nil }
        if n == 1, pairsWithFollowingNotehead(at: naturalAccs[0].index, in: sorted) {
            return nil
        }
        return KeySignature(concertKey: 0)
    }

    /// A naturals-only cancellation engraved as a COURTESY at the END of a
    /// measure — the ♮ block drawn after the last note, just before the
    /// barline, when the change to C major falls on the next system's first
    /// measure (a system-break key change: MuseScore shows the cancellation
    /// at the end of the outgoing system and nothing at the incoming
    /// system's start, so the leading reader never sees it —
    /// チャンカパーナ 3♯→C effective m27, drawn trailing in m26). The caller
    /// applies the returned key at measure `i + 1`, mirroring
    /// `readTrailingClef`.
    ///
    /// Scoped to naturals only: a courtesy that introduces a NON-C key shows
    /// that key's sharp/flat block, which the NEXT system's leading measure
    /// re-shows and `readKey` reads there — so a trailing sharp/flat is left
    /// alone here (returning nil) to avoid a miscount. `readNaturalsCancellation`
    /// enforces the full-ladder match.
    static func readTrailingKey(
        sorted: [ClassifiedGlyph], clef: Clef, yLines: [CGFloat],
        runningKey: KeySignature,
    ) -> KeySignature? {
        guard runningKey.concertKey != 0,
              let anchor = staffAnchor(clef: clef, yLines: yLines),
              anchor.lineSpacing > 0
        else { return nil }
        var lastContentX: CGFloat?
        for g in sorted {
            let isRest = if case .rest = g.semantic { true } else { false }
            if isNotehead(g.semantic) || isRest { lastContentX = g.geometry.origin.x }
        }
        guard let lastContentX else { return nil }
        let halfStep = anchor.lineSpacing / 2
        var naturalAccs: [(index: Int, sa: Int, x: CGFloat)] = []
        for (i, g) in sorted.enumerated() where g.geometry.origin.x > lastContentX {
            guard let alt = accidentalAlteration(g.semantic) else { continue }
            if alt != 0 { return nil }
            let sa = Int(((g.geometry.origin.y - anchor.bottomY) / halfStep).rounded())
            naturalAccs.append((i, sa, g.geometry.origin.x))
        }
        return readNaturalsCancellation(
            naturalAccs: naturalAccs, runningKey: runningKey,
            anchor: anchor, sorted: sorted,
        )
    }

    /// Longest prefix of `accs` (x-ordered, single accidental type) that
    /// matches `ladder` position-by-position **and** stays x-cohesive
    /// (consecutive members within ~1.5 line spacings — key-signature
    /// accidentals pack ~one space apart). Stops at the first position failing
    /// either test, so a trailing local accidental beyond the block (wider x
    /// gap, or off the ladder) is never absorbed.
    private static func ladderPrefixCount(
        _ accs: [(sa: Int, x: CGFloat)], ladder: [Int], lineSpacing: CGFloat,
    ) -> Int {
        let maxGap = lineSpacing * 1.6
        var n = 0
        var prevX: CGFloat?
        for acc in accs {
            guard n < ladder.count, acc.sa == ladder[n] else { break }
            if let prevX, acc.x - prevX > maxGap { break }
            n += 1
            prevX = acc.x
        }
        return n
    }

    /// Legacy proximity-based key reader — retained only as the fallback when
    /// no staff anchor is available (degenerate / missing staff lines, where
    /// the measure also decodes no pitched content, so the value is moot).
    private static func readKeyLegacy(sorted: [ClassifiedGlyph]) -> KeySignature? {
        var sharps = 0
        var flats = 0
        for (i, glyph) in sorted.enumerated() {
            switch glyph.semantic {
            case .accidentalSharp:
                if !pairsWithFollowingNotehead(at: i, in: sorted) { sharps += 1 }
            case .accidentalFlat, .accidentalNatural:
                if !pairsWithFollowingNotehead(at: i, in: sorted) {
                    if case .accidentalFlat = glyph.semantic { flats += 1 }
                }
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                return finalize(sharps: sharps, flats: flats)
            default: continue
            }
        }
        return finalize(sharps: sharps, flats: flats)
    }

    /// True when the accidental at `index` is a LOCAL accidental: a
    /// notehead follows it at (near) the same y and close in x — the
    /// visual signature of an accidental modifying that single note,
    /// rather than a key-signature accidental (which sits at a canonical
    /// staff position with the notes spaced well to its right).
    private static func pairsWithFollowingNotehead(
        at index: Int, in sorted: [ClassifiedGlyph],
    ) -> Bool {
        let acc = sorted[index]
        guard index + 1 < sorted.count else { return false }
        for j in (index + 1) ..< sorted.count {
            let g = sorted[j]
            switch g.semantic {
            case .noteheadBlack, .noteheadHalf,
                 .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                let dx = g.geometry.origin.x - acc.geometry.origin.x
                let dy = abs(g.geometry.origin.y - acc.geometry.origin.y)
                // Local accidental: notehead is just to the right (≤ ~14pt)
                // at essentially the same y (≤ ~2pt, i.e. same staff line).
                return dx >= 0 && dx <= 14 && dy <= 2
            default:
                continue
            }
        }
        return false
    }

    private static func finalize(sharps: Int, flats: Int) -> KeySignature? {
        if sharps > 0 { return KeySignature(concertKey: sharps) }
        if flats > 0 { return KeySignature(concertKey: -flats) }
        return nil
    }
}
