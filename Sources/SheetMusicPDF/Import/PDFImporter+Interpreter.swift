#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// The front-end contract. Every source format produces this; `buildScore`
/// consumes nothing else.
///
/// Implementations today: the Apple `CGPDFScanner` walker
/// (`PDFImporter+ContentStream`) and the Foundation-only pure-Swift reader
/// (`PDFImporter+SwiftReader`). A raster / OMR front-end fills the same four
/// streams: staff lines and stems become `.horizontal` / `.vertical`
/// `PathSegment`s, beams become `.beam` segments with a fitted `BeamQuad`,
/// ties and slurs become `CurveArc`s, recognized symbols become
/// `ClassifiedGlyph`s, and text runs become `TextGlyph`s.
///
/// CONTRACT RULE — determinism. A front-end, and every pass it feeds, must not
/// depend on `Dictionary` / `Set` iteration order; traverse in geometric or
/// sorted order. Swift randomizes hash seeds per process, and an
/// order-dependent pass once made the same PDF score 96% or 9% across runs.
/// Nothing measurement-gated is trustworthy until this holds.
///
/// Coordinates are PDF page space (origin = bottom-left), aggregated across
/// all pages; `pageIndex` on each element selects the page.
struct WalkedContent {
    var glyphs: [ClassifiedGlyph]
    var texts: [TextGlyph]
    var paths: [PathSegment]
    var curves: [CurveArc] = []
}

// Content-stream interpreter core — the per-operator effect on `PageState`,
// expressed as methods that take ALREADY-PARSED operands (no CoreGraphics
// scanner handle). The Apple front-end (`PDFImporter+ContentStream+Operators`)
// pops operands off `CGPDFScanner` and calls these; the future Android
// tokenizer front-end will parse operands from raw content bytes and call the
// SAME methods. This is what keeps the two platforms' PDF decode identical by
// construction — only the byte→operand front-end differs.
//
// Every method here mirrors exactly one op_* callback's former inline body;
// the operand ORDER is fixed by the caller (which pops in PDF stack order), so
// these take values already in natural argument order.
//
// See docs/superpowers/specs/2026-07-12-pdf-import-android-design.md §4, §6.

extension PDFPageState {
    // MARK: Graphics state

    /// `q` — push a copy of the current CTM.
    func opPushGraphicsState() {
        ctmStack.append(ctm)
    }

    /// `Q` — pop the CTM (never below the base entry).
    func opPopGraphicsState() {
        if ctmStack.count > 1 { ctmStack.removeLast() }
    }

    /// `cm` — concatenate `m` into the current CTM.
    func opConcatCTM(_ m: CGAffineTransform) {
        setTopCTM(m.concatenating(ctm))
    }

    /// `w` — set line width.
    func opSetLineWidth(_ width: CGFloat) {
        lineWidth = width
    }

    // MARK: Text state

    /// `BT` — begin text: reset the text + line matrices to identity.
    func opBeginText() {
        textMatrix = .identity
        lineMatrix = .identity
    }

    /// `Tf` — set font size and (by resource name) the active ToUnicode CMap.
    /// `nil` name/size leave the corresponding field unchanged, matching the
    /// former callback (which only assigned when the pop succeeded).
    func opSetFont(name: String?, size: CGFloat?) {
        if let size { fontSize = size }
        if let name {
            fontName = name
            // nil when the font has no usable /ToUnicode (e.g. ASCII Helvetica
            // fixtures), which keeps the legacy UTF-8/Latin-1 decode active.
            activeCMap = fontCMaps[name]
            // Recomputed per `Tf`, not per glyph — see the property.
            activeCMapHasStandardSMuFLEvidence =
                activeCMap?.mapsRecognizedStandardSMuFLCodepoints ?? false
            activeSimpleFontDecoder = simpleFontDecoders[name]
            #if canImport(CoreGraphics)
                activeClassifier = classifiers[name]
            #endif
        }
    }

    /// `Tm` — set the text and line matrices.
    func opSetTextMatrix(_ m: CGAffineTransform) {
        textMatrix = m
        lineMatrix = m
    }

    /// `Td` / `TD` — move to the next line origin by (tx, ty).
    func opTextMove(tx: CGFloat, ty: CGFloat) {
        let translated = CGAffineTransform(translationX: tx, y: ty)
            .concatenating(lineMatrix)
        lineMatrix = translated
        textMatrix = translated
    }

    /// `T*` — move to the start of the next line.
    func opTextNextLine() {
        textMatrix = lineMatrix
    }

    // MARK: Text show

    /// `Tj` / `TJ` element — show a string operand at the current text origin.
    func opShow(_ bytes: [UInt8]) {
        emitShow(bytes, state: self)
    }

    /// `'` / `"` — move to the next line, then show. (The `"` word/char
    /// spacing operands are dropped by the caller, as before.)
    func opShowNextLine(_ bytes: [UInt8]) {
        textMatrix = lineMatrix
        emitShow(bytes, state: self)
    }

    // MARK: Path construction

    /// `m` — begin a new subpath at (x, y).
    func opMoveTo(x: CGFloat, y: CGFloat) {
        let p = CGPoint(x: x, y: y)
        currentPoint = p
        // The first `m` of a fresh path captures the CTM; subsequent `m`s
        // inside the same un-painted path just continue accumulating points.
        if pendingPolyPoints.isEmpty {
            pendingPolyCTM = ctm
        }
        pendingPolyPoints.append(p)
    }

    /// `l` — straight line to (x, y).
    func opLineTo(x: CGFloat, y: CGFloat) {
        let next = CGPoint(x: x, y: y)
        if let cur = currentPoint {
            pendingLines.append((cur, next, ctm))
        }
        currentPoint = next
        pendingPolyPoints.append(next)
    }

    /// `re` — append a rectangle.
    func opAppendRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        pendingRects.append((CGRect(x: x, y: y, width: width, height: height), ctm))
    }

    /// `c` / `v` / `y` — Bezier curve; only the endpoint matters for the tie
    /// / slur lens outline (nil when operands were malformed).
    func opCurve(endX: CGFloat?, endY: CGFloat?) {
        pendingPolyHasCurve = true
        if let endX, let endY {
            let end = CGPoint(x: endX, y: endY)
            currentPoint = end
            pendingPolyPoints.append(end)
        } else {
            currentPoint = nil
        }
    }

    // MARK: Painting

    /// `f` / `F` / `f*` / `B` / `B*` / `b` / `b*` — fill (runs beam-quad /
    /// curve-arc detection).
    func opFill() {
        flushPaintedPath(fill: true)
    }

    /// `S` / `s` — stroke (no beam detection; beams are always filled).
    func opStroke() {
        flushPaintedPath(fill: false)
    }

    /// `n` / `W` / `W*` — end the path without painting.
    func opEndPath() {
        resetPath()
    }
}
