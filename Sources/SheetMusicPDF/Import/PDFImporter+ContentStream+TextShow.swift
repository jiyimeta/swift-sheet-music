#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Text-show emission for the content-stream walker. Split out of the
// operator-callback file so neither exceeds the 400-line file cap. The
// `Tj` / `TJ` / `'` / `"` callbacks (in PDFImporter+ContentStream+Operators)
// call `emitShow`, which routes each decoded scalar to a music
// `ClassifiedGlyph` (SMuFL PUA) or a `TextGlyph` text run.

typealias TextShowState = PDFPageState
private typealias State = TextShowState

/// SMuFL Private Use Area range. A decoded scalar inside this range is
/// a music glyph (Leland / LelandText) → ClassifiedGlyph; otherwise it's
/// ordinary text → TextGlyph.
private let smuflPUARange: ClosedRange<UInt32> = 0xE000 ... 0xF8FF

/// Emit a show-string operand. When an active ToUnicode CMap is present
/// (Type0 / Identity-H fonts), iterate the operand in 2-byte CID codes,
/// map each through the CMap, and route the decoded scalar(s): PUA
/// scalars become a `ClassifiedGlyph` at the current per-glyph origin;
/// non-PUA scalars accumulate into a `TextGlyph` text run.
///
/// MuseScore positions each music glyph with its own `Tm`/`cm` (observed
/// in ギブス.pdf: one BT/ET block per glyph, `Td [0 0]`), so the
/// current-text-matrix origin is already the accurate per-glyph origin.
/// We still advance the text matrix per glyph so any back-to-back codes
/// in a single run land at successive positions.
func emitShow(_ bytes: [UInt8], state: TextShowState) {
    guard let cmap = state.activeCMap, !cmap.isEmpty else {
        #if canImport(CoreGraphics)
            if let classifier = state.activeClassifier, classifier.canClassifyWithoutCMap {
                emitShowSimpleFont(bytes, state: state, classifier: classifier)
                return
            }
        #endif
        emitText(decodeString(bytes), state: state)
        return
    }
    let length = bytes.count
    guard length > 0 else { return }

    var pendingText = ""
    var i = 0
    // Identity-H: 2 bytes per CID.
    while i + 1 < length {
        let cid = (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
        i += 2
        guard let scalars = cmap.scalars(cid: cid), let first = scalars.first
        else {
            advanceTextMatrix(state: state, glyphCount: 1)
            continue
        }
        let semantic = classifyCID(cid, codepoint: first.value, state: state)
        if isMusicGlyph(semantic: semantic, codepoint: first.value, state: state) {
            flushPendingText(&pendingText, state: state)
            let origin = currentOrigin(state: state)
            let advance = glyphAdvance(state: state)
            state.glyphs.append(ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: origin,
                    advance: advance,
                    renderedSize: renderedSize(state: state),
                    pageIndex: state.pageIndex,
                    fontSize: state.fontSize,
                ),
                semantic: semantic,
            ))
            advanceTextMatrix(state: state, glyphCount: 1)
        } else {
            for s in scalars {
                pendingText.unicodeScalars.append(s)
            }
            advanceTextMatrix(state: state, glyphCount: 1)
        }
    }
    // Odd trailing byte (shouldn't happen for Identity-H) — ignore.
    flushPendingText(&pendingText, state: state)
}

/// Resolve one CMap-decoded CID to a semantic.
///
/// Tier 1 (SMuFL PUA codepoint) answers every glyph in every MuseScore /
/// Dorico / Finale 27+ PDF. For a non-SMuFL-encoded producer (Finale
/// Maestro, Sibelius Opus, …) `activeClassifier` widens this with Tier 2
/// (glyph name) / Tier 4 (outline shape).
///
/// `characterCode: nil` — a CID is not a character code in a simple font's
/// own encoding, so `/Differences` (Tier 2's key space) must not be indexed
/// with it.
private func classifyCID(
    _ cid: UInt32, codepoint: UInt32, state: State,
) -> SMuFLSemantic {
    #if canImport(CoreGraphics)
        state.activeClassifier.map {
            $0.classify(
                codepoint: codepoint, characterCode: nil,
                glyphID: CGGlyph(truncatingIfNeeded: cid),
            )
        } ?? PDFImporter.smuflSemantic(codepoint: codepoint)
    #else
        PDFImporter.smuflSemantic(codepoint: codepoint)
    #endif
}

/// Route a decoded scalar to the music stream or the text stream.
///
/// A non-PUA scalar becomes music ONLY when a tier positively identifies
/// it; a PUA scalar no tier recognizes still becomes an `.unknown` music
/// glyph exactly as before, so the diagnostic path for MuseScore's own
/// byte-identical output is unchanged.
///
/// TESTING ONLY: `anchorMusicToPUARange` (see
/// `PDFImportOptions.anchorMusicGlyphsToPUARange`) forces this decision to
/// depend solely on the raw codepoint, ignoring what the classifier
/// answered, so the Tier-1 ablation promotes the same codepoint set
/// regardless of which tier supplied the semantic.
private func isMusicGlyph(
    semantic: SMuFLSemantic, codepoint: UInt32, state: State,
) -> Bool {
    if state.anchorMusicToPUARange { return smuflPUARange.contains(codepoint) }
    if case .unknown = semantic { return smuflPUARange.contains(codepoint) }
    return true
}

#if canImport(CoreGraphics)
    /// A text run accumulating inside one show-string operand, carrying the
    /// text origin as of the moment its FIRST code was appended.
    ///
    /// The origin has to be captured up front because the loop advances the
    /// text matrix per code: reading `currentOrigin` at flush time would
    /// place the whole run at the position AFTER its last code. A legacy
    /// simple font puts a whole word or line in one `Tj`, so that error is
    /// the run's full width — enough to break lyric-to-note attachment.
    private struct PendingTextRun {
        private(set) var text = ""
        private(set) var origin: CGPoint = .zero

        var isEmpty: Bool {
            text.isEmpty
        }

        mutating func append(_ scalar: Unicode.Scalar, startingAt start: CGPoint) {
            if text.isEmpty { origin = start }
            text.unicodeScalars.append(scalar)
        }
    }

    /// Emit a show-string operand for a simple font with NO usable
    /// `/ToUnicode` but a usable embedded program or `/Differences` — the
    /// legacy-music-font case (Maestro, Opus, Sonata) P1 targets. A simple
    /// font uses 1-byte codes, not Identity-H's 2.
    ///
    /// The byte is a CHARACTER CODE in the font's own encoding, which is the
    /// key Tier 2 looks up in `/Encoding /Differences`. It is NOT in general
    /// the glyph ID Tier 4 needs: measured on real Finale output, a subsetted
    /// simple font's content-stream bytes are its PRE-subset character codes
    /// (207, 35, 98, 46, …), outside the compacted glyph-ID range, and
    /// `CTFontCreatePathForGlyph` returns nil for every one of them. Passing
    /// the byte as the glyph ID below is therefore a placeholder that only
    /// happens to hold for an identity-encoded font; reaching a subsetted
    /// font's outline needs code → glyph ID resolved through the font's own
    /// encoding (not yet implemented — Tier 4 is off by default meanwhile).
    ///
    /// NO corpus coverage: every corpus PDF is MuseScore output with a
    /// proper CMap, so this path is exercised only by unit tests and by the
    /// real-file acceptance check.
    private func emitShowSimpleFont(
        _ bytes: [UInt8], state: State, classifier: GlyphClassifier,
    ) {
        var pending = PendingTextRun()
        for byte in bytes {
            let code = UInt32(byte)
            let semantic = classifier.classify(
                codepoint: code, characterCode: code, glyphID: CGGlyph(byte),
            )
            if case .unknown = semantic {
                pending.append(Unicode.Scalar(byte), startingAt: currentOrigin(state: state))
                advanceTextMatrix(state: state, glyphCount: 1)
                continue
            }
            flushPendingRun(&pending, state: state)
            let origin = currentOrigin(state: state)
            let advance = glyphAdvance(state: state)
            state.glyphs.append(ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: origin,
                    advance: advance,
                    renderedSize: renderedSize(state: state),
                    pageIndex: state.pageIndex,
                    fontSize: state.fontSize,
                ),
                semantic: semantic,
            ))
            advanceTextMatrix(state: state, glyphCount: 1)
        }
        flushPendingRun(&pending, state: state)
    }

    /// Emit an accumulated run at the origin it STARTED at, then reset.
    private func flushPendingRun(_ run: inout PendingTextRun, state: State) {
        guard !run.isEmpty else { return }
        emitTextGlyph(run.text, at: run.origin, state: state)
        run = PendingTextRun()
    }
#endif

/// Page-space origin of the current text position.
private func currentOrigin(state: State) -> CGPoint {
    CGPoint.zero.applying(state.textMatrix).applying(state.ctm)
}

/// Effective page-space rendered glyph size. The Tf operand (`fontSize`)
/// is uniform across the score (100pt in ギブス.pdf); the per-glyph size
/// is set by the combined text-matrix × CTM scale. A grace / cue notehead
/// is drawn through a down-scaled matrix, so this is the discriminating
/// signal. Uses the uniform scale = sqrt(|det|) of the combined matrix.
private func renderedSize(state: State) -> CGFloat {
    let m = state.textMatrix.concatenating(state.ctm)
    let det = abs(m.a * m.d - m.b * m.c)
    return state.fontSize * sqrt(det)
}

/// Approximate per-glyph advance in page points. The CIDFont /W widths
/// are not consulted (every observed music glyph is placed by its own
/// absolute matrix, so the advance is cosmetic here). Estimate from the
/// font size scaled by the CTM so the value is in page units.
private func glyphAdvance(state: State) -> CGFloat {
    let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
    return state.fontSize * 0.5 * scale
}

/// Advance the text matrix by an approximate glyph width so any
/// subsequent code in the same run lands further along.
private func advanceTextMatrix(state: State, glyphCount: Int) {
    let approxAdvance = state.fontSize * 0.5 * CGFloat(glyphCount)
    state.textMatrix = CGAffineTransform(translationX: approxAdvance, y: 0)
        .concatenating(state.textMatrix)
}

/// Emit the accumulated non-PUA text as a `TextGlyph` and reset.
///
/// Emits at the text position as of the FLUSH, not as of the run's first
/// code — behavior this branch inherited and left alone. It is only ever
/// wrong by the run's own width, and for the CMap path that width is
/// small: MuseScore emits one BT/ET block per glyph, so a run here is
/// usually a single code. The whole downstream lyric geometry was
/// calibrated against these positions across nine sessions, so moving them
/// is a measured experiment in its own right, not a drive-by fix. The
/// simple-font path, where a run really is a whole word, captures its
/// start origin instead — see `PendingTextRun`.
private func flushPendingText(_ pending: inout String, state: State) {
    guard !pending.isEmpty else { return }
    emitTextGlyph(pending, at: currentOrigin(state: state), state: state)
    pending = ""
}

/// Decode a Tj/TJ string operand for fonts WITHOUT a usable CMap. Test
/// fixtures use Helvetica with ASCII bytes — treating them as UTF-8 is
/// correct there.
private func decodeString(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "" }
    let data = Data(bytes)
    if let utf8 = String(bytes: data, encoding: .utf8) { return utf8 }
    return String(bytes: data, encoding: .isoLatin1) ?? ""
}

/// Emit a `TextGlyph` for a decoded text run at the current text
/// origin in page coordinates, then advance the text matrix by an
/// approximate width so subsequent `Tj`s in the same run land
/// further right (tests don't pin advance precision).
private func emitText(_ text: String, state: State) {
    guard !text.isEmpty else { return }
    emitTextGlyph(text, at: currentOrigin(state: state), state: state)
    let approxAdvance = state.fontSize * 0.5 * CGFloat(text.count)
    state.textMatrix = CGAffineTransform(translationX: approxAdvance, y: 0)
        .concatenating(state.textMatrix)
}

/// Append a `TextGlyph` at `origin` in page coordinates (no advance — the
/// caller decides whether/how to advance the text matrix).
private func emitTextGlyph(_ text: String, at origin: CGPoint, state: State) {
    state.texts.append(TextGlyph(
        text: text,
        fontName: state.fontName,
        fontSize: state.fontSize,
        origin: origin,
        bbox: .zero,
        pageIndex: state.pageIndex,
    ))
}
