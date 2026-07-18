#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Foundation-only PDF front-end: the Android counterpart of the Apple
// `CGPDFScanner` walker. Parses `pdfData` with the pure-Swift `PDFReaderDocument`,
// tokenizes each page's content stream, and drives the SAME shared interpreter
// (`PDFPageState` + the `op*()` methods) the Apple front-end drives — so both
// platforms produce identical `WalkedContent`.
//
// See docs/superpowers/specs/2026-07-12-pdf-import-android-design.md §4, §6.

extension PDFImporter {
    /// Walk `pdfData` with the pure-Swift reader and return the same tuple the
    /// Apple `walkDocument` produces: aggregated `WalkedContent`, per-page
    /// mediaBox sizes, page count, and /Info attributes. Returns nil when the
    /// bytes are not a parseable PDF.
    static func walkWithSwiftReader(
        pdfData: Data,
    ) -> (content: WalkedContent, pageCount: Int, pageSizes: [Int: CGSize], attributes: [String: Any]?)? {
        guard let doc = PDFReaderDocument(data: pdfData) else { return nil }
        var glyphs: [RawGlyph] = []
        var texts: [TextGlyph] = []
        var paths: [PathSegment] = []
        var curves: [CurveArc] = []
        var pageSizes: [Int: CGSize] = [:]
        for page in 0 ..< doc.pageCount {
            if let size = doc.mediaBox(page: page) { pageSizes[page] = size }
            let state = PDFPageState(pageIndex: page)
            state.fontCMaps = decodeFontCMaps(doc.fontToUnicodeStreams(page: page))
            let bytes = [UInt8](doc.contentBytes(page: page))
            for op in PDFContentTokenizer.tokenize(bytes) {
                applyContentOp(op, to: state)
            }
            glyphs.append(contentsOf: state.glyphs)
            texts.append(contentsOf: state.texts)
            paths.append(contentsOf: state.paths)
            curves.append(contentsOf: state.curveArcs)
        }
        let content = WalkedContent(glyphs: glyphs, texts: texts, paths: paths, curves: curves)
        return (content, doc.pageCount, pageSizes, doc.documentAttributes)
    }

    /// Decode each `/ToUnicode` CMap byte-stream into a `ToUnicodeCMap`,
    /// dropping fonts whose CMap is empty/unusable (matching `extractFontCMaps`).
    private static func decodeFontCMaps(_ streams: [String: Data]) -> [String: ToUnicodeCMap] {
        var out: [String: ToUnicodeCMap] = [:]
        for (name, data) in streams {
            let cmap = ToUnicodeCMap.parse(data: data)
            if !cmap.isEmpty { out[name] = cmap }
        }
        return out
    }

    /// Map one tokenized content operator (operands in STREAM/forward order) to
    /// the shared interpreter methods on `PDFPageState`. Mirrors the Apple
    /// `op_*` callbacks exactly (which pop operands in reverse; here they arrive
    /// forward, so indices read left-to-right).
    private static func applyContentOp(_ op: PDFContentOp, to s: PDFPageState) {
        let a = op.operands
        switch op.op {
        case "q": s.opPushGraphicsState()
        case "Q": s.opPopGraphicsState()
        case "cm": if let m = matrix(a) { s.opConcatCTM(m) }
        case "w": if let v = number(a, 0) { s.opSetLineWidth(v) }
        case "BT": s.opBeginText()
        case "Tf": s.opSetFont(name: nameOperand(a, 0), size: number(a, 1))
        case "Tm": if let m = matrix(a) { s.opSetTextMatrix(m) }
        case "Td", "TD":
            if let tx = number(a, 0), let ty = number(a, 1) { s.opTextMove(tx: tx, ty: ty) }
        case "T*": s.opTextNextLine()
        case "Tj": if let b = bytes(a, 0) { s.opShow(b) }
        case "'": if let b = bytes(a, 0) { s.opShowNextLine(b) }
        case "\"": if let b = bytes(a, 2) { s.opShowNextLine(b) } // aw ac string
        case "TJ":
            if case let .array(elems)? = a.first {
                for e in elems {
                    if case let .string(b) = e { s.opShow(b) }
                }
            }
        case "m": if let x = number(a, 0), let y = number(a, 1) { s.opMoveTo(x: x, y: y) }
        case "l": if let x = number(a, 0), let y = number(a, 1) { s.opLineTo(x: x, y: y) }
        case "re":
            if let x = number(a, 0), let y = number(a, 1),
               let w = number(a, 2), let h = number(a, 3)
            { s.opAppendRect(x: x, y: y, width: w, height: h) }
        case "c": s.opCurve(endX: number(a, 4), endY: number(a, 5))
        case "v", "y": s.opCurve(endX: number(a, 2), endY: number(a, 3))
        case "f", "F", "f*", "B", "B*", "b", "b*": s.opFill()
        case "S", "s": s.opStroke()
        case "n", "W", "W*": s.opEndPath()
        default: break // ET, h, BDC/DP/EMC, gs, and other ignored operators
        }
    }

    private static func number(_ a: [PDFOperand], _ i: Int) -> CGFloat? {
        guard i < a.count, case let .number(v) = a[i] else { return nil }
        return v
    }

    private static func nameOperand(_ a: [PDFOperand], _ i: Int) -> String? {
        guard i < a.count, case let .name(n) = a[i] else { return nil }
        return n
    }

    private static func bytes(_ a: [PDFOperand], _ i: Int) -> [UInt8]? {
        guard i < a.count, case let .string(b) = a[i] else { return nil }
        return b
    }

    private static func matrix(_ a: [PDFOperand]) -> CGAffineTransform? {
        guard let m0 = number(a, 0), let m1 = number(a, 1), let m2 = number(a, 2),
              let m3 = number(a, 3), let m4 = number(a, 4), let m5 = number(a, 5)
        else { return nil }
        return CGAffineTransform(a: m0, b: m1, c: m2, d: m3, tx: m4, ty: m5)
    }
}
