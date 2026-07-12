import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// Text-show emission for the content-stream walker. Split out of the
// operator-callback file so neither exceeds the 400-line file cap. The
// `Tj` / `TJ` / `'` / `"` callbacks (in PDFImporter+ContentStream+Operators)
// call `emitShow`, which routes each decoded scalar to a music `RawGlyph`
// (SMuFL PUA) or a `TextGlyph` text run.

typealias TextShowState = PDFPageState
private typealias State = TextShowState

/// SMuFL Private Use Area range. A decoded scalar inside this range is
/// a music glyph (Leland / LelandText) → RawGlyph; otherwise it's
/// ordinary text → TextGlyph.
private let smuflPUARange: ClosedRange<UInt32> = 0xE000 ... 0xF8FF

/// Emit a show-string operand. When an active ToUnicode CMap is present
/// (Type0 / Identity-H fonts), iterate the operand in 2-byte CID codes,
/// map each through the CMap, and route the decoded scalar(s): PUA
/// scalars become a `RawGlyph` at the current per-glyph origin; non-PUA
/// scalars accumulate into a `TextGlyph` text run.
///
/// MuseScore positions each music glyph with its own `Tm`/`cm` (observed
/// in ギブス.pdf: one BT/ET block per glyph, `Td [0 0]`), so the
/// current-text-matrix origin is already the accurate per-glyph origin.
/// We still advance the text matrix per glyph so any back-to-back codes
/// in a single run land at successive positions.
func emitShow(_ bytes: [UInt8], state: TextShowState) {
    guard let cmap = state.activeCMap, !cmap.isEmpty else {
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
        if smuflPUARange.contains(first.value) {
            flushPendingText(&pendingText, state: state)
            let origin = currentOrigin(state: state)
            let advance = glyphAdvance(state: state)
            state.glyphs.append(RawGlyph(
                codepoint: first.value,
                fontName: state.fontName,
                fontSize: state.fontSize,
                origin: origin,
                advance: advance,
                pageIndex: state.pageIndex,
                renderedSize: renderedSize(state: state),
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
private func flushPendingText(_ pending: inout String, state: State) {
    guard !pending.isEmpty else { return }
    emitTextGlyph(pending, state: state)
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
    emitTextGlyph(text, state: state)
    let approxAdvance = state.fontSize * 0.5 * CGFloat(text.count)
    state.textMatrix = CGAffineTransform(translationX: approxAdvance, y: 0)
        .concatenating(state.textMatrix)
}

/// Append a `TextGlyph` at the current text origin (no advance — the
/// caller decides whether/how to advance the text matrix).
private func emitTextGlyph(_ text: String, state: State) {
    let originPageSpace = currentOrigin(state: state)
    state.texts.append(TextGlyph(
        text: text,
        fontName: state.fontName,
        fontSize: state.fontSize,
        origin: originPageSpace,
        bbox: .zero,
        pageIndex: state.pageIndex,
    ))
}
