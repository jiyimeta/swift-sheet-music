import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// MARK: - Operator-table registration

/// Registration helpers for the content-stream walker. A separate file so
/// the C-callback bodies do not push the main walker source past the
/// 300-line file cap.
///
/// Every callback below is a file-scope `@convention(c)` function (not a
/// closure literal). That keeps each callback capture-free *and* sidesteps
/// a SIL `SendNonSendable` crasher in Swift 6 strict-concurrency mode that
/// triggers when a method body holds many of these callbacks inline.
enum ContentStreamOperators {
    typealias State = PDFImporter.ContentStreamWalker.PageState

    static func register(on table: CGPDFOperatorTableRef) {
        // Graphics-state stack and CTM.
        CGPDFOperatorTableSetCallback(table, "q", op_q)
        CGPDFOperatorTableSetCallback(table, "Q", op_Q)
        CGPDFOperatorTableSetCallback(table, "cm", op_cm)
        CGPDFOperatorTableSetCallback(table, "w", op_w)

        // Text state.
        CGPDFOperatorTableSetCallback(table, "BT", op_BT)
        CGPDFOperatorTableSetCallback(table, "ET", op_noop)
        CGPDFOperatorTableSetCallback(table, "Tf", op_Tf)
        CGPDFOperatorTableSetCallback(table, "Tm", op_Tm)
        CGPDFOperatorTableSetCallback(table, "Td", op_Td)
        CGPDFOperatorTableSetCallback(table, "TD", op_TD)
        CGPDFOperatorTableSetCallback(table, "T*", op_Tstar)

        // Text-show.
        CGPDFOperatorTableSetCallback(table, "Tj", op_Tj)
        CGPDFOperatorTableSetCallback(table, "'", op_quote)
        CGPDFOperatorTableSetCallback(table, "\"", op_dquote)
        CGPDFOperatorTableSetCallback(table, "TJ", op_TJ)

        // Path construction.
        CGPDFOperatorTableSetCallback(table, "m", op_m)
        CGPDFOperatorTableSetCallback(table, "l", op_l)
        CGPDFOperatorTableSetCallback(table, "re", op_re)
        CGPDFOperatorTableSetCallback(table, "h", op_noop)
        CGPDFOperatorTableSetCallback(table, "c", op_c)
        CGPDFOperatorTableSetCallback(table, "v", op_v)
        CGPDFOperatorTableSetCallback(table, "y", op_y)

        // Painting operators that flush the in-progress path. Fill (and
        // fill-and-stroke) variants run beam-quad detection; pure strokes
        // do not (a beam is always filled).
        CGPDFOperatorTableSetCallback(table, "S", op_stroke)
        CGPDFOperatorTableSetCallback(table, "s", op_stroke)
        CGPDFOperatorTableSetCallback(table, "f", op_fill)
        CGPDFOperatorTableSetCallback(table, "F", op_fill)
        CGPDFOperatorTableSetCallback(table, "f*", op_fill)
        CGPDFOperatorTableSetCallback(table, "B", op_fill)
        CGPDFOperatorTableSetCallback(table, "B*", op_fill)
        CGPDFOperatorTableSetCallback(table, "b", op_fill)
        CGPDFOperatorTableSetCallback(table, "b*", op_fill)

        // n: end path without painting; W/W*: clipping markers.
        CGPDFOperatorTableSetCallback(table, "n", op_drop)
        CGPDFOperatorTableSetCallback(table, "W", op_drop)
        CGPDFOperatorTableSetCallback(table, "W*", op_drop)
    }
}

// MARK: - File-scope callbacks

private typealias State = PDFImporter.ContentStreamWalker.PageState

private func op_noop(_: CGPDFScannerRef, _: UnsafeMutableRawPointer?) {}

private func op_q(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    s.ctmStack.append(s.ctm)
}

private func op_Q(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    if s.ctmStack.count > 1 { s.ctmStack.removeLast() }
}

private func op_cm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let m = popMatrix(scanner) else { return }
    s.setTopCTM(m.concatenating(s.ctm))
}

private func op_w(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let v = popNumber(scanner) else { return }
    s.lineWidth = v
}

private func op_BT(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    s.textMatrix = .identity
    s.lineMatrix = .identity
}

private func op_Tf(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    if let size = popNumber(scanner) { s.fontSize = size }
    if let name = popName(scanner) {
        s.fontName = name
        // Select the ToUnicode CMap for this font resource. nil when the
        // font has no usable /ToUnicode (e.g. ASCII Helvetica fixtures),
        // which keeps the legacy UTF-8/Latin-1 decode path active.
        s.activeCMap = s.fontCMaps[name]
    }
}

private func op_Tm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let m = popMatrix(scanner) else { return }
    s.textMatrix = m
    s.lineMatrix = m
}

private func op_Td(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let ty = popNumber(scanner),
          let tx = popNumber(scanner) else { return }
    let translated = CGAffineTransform(translationX: tx, y: ty).concatenating(s.lineMatrix)
    s.lineMatrix = translated
    s.textMatrix = translated
}

private func op_TD(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    op_Td(scanner, info)
}

private func op_Tstar(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    s.textMatrix = s.lineMatrix
}

private func op_Tj(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    emitShow(str, state: s)
}

private func op_TJ(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let arr = popArray(scanner) else { return }
    let count = CGPDFArrayGetCount(arr)
    for i in 0 ..< count {
        var str: CGPDFStringRef?
        if CGPDFArrayGetString(arr, i, &str), let str {
            emitShow(str, state: s)
        }
        // Numbers are kerning offsets — ignored for our walker.
    }
}

private func op_quote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    s.textMatrix = s.lineMatrix
    emitShow(str, state: s)
}

private func op_dquote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    _ = popNumber(scanner) // word spacing
    _ = popNumber(scanner) // char spacing
    s.textMatrix = s.lineMatrix
    emitShow(str, state: s)
}

private func op_m(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    let p = CGPoint(x: x, y: y)
    s.currentPoint = p
    // Begin a new subpath polygon. The first `m` of a fresh path captures
    // the CTM; subsequent `m`s inside the same un-painted path (rare for
    // beams) just continue accumulating points.
    if s.pendingPolyPoints.isEmpty {
        s.pendingPolyCTM = s.ctm
    }
    s.pendingPolyPoints.append(p)
}

private func op_l(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    let next = CGPoint(x: x, y: y)
    if let cur = s.currentPoint {
        s.pendingLines.append((cur, next, s.ctm))
    }
    s.currentPoint = next
    s.pendingPolyPoints.append(next)
}

private func op_re(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let h = popNumber(scanner),
          let w = popNumber(scanner),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    s.pendingRects.append((CGRect(x: x, y: y, width: w, height: h), s.ctm))
}

private func op_c(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 6 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    // Operands pop in reverse; the cubic's endpoint is the first pair shown
    // in the stream → the last two values popped (nums[5], nums[4]).
    captureCurve(s, endX: nums.count == 6 ? nums[5] : nil, endY: nums.count == 6 ? nums[4] : nil)
}

private func op_v(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 4 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    captureCurve(s, endX: nums.count == 4 ? nums[3] : nil, endY: nums.count == 4 ? nums[2] : nil)
}

private func op_y(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 4 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    captureCurve(s, endX: nums.count == 4 ? nums[3] : nil, endY: nums.count == 4 ? nums[2] : nil)
}

/// Record a Bezier segment: flag the subpath as curved (so it can't be
/// read as a beam) and append the curve's endpoint to the subpath polygon.
/// The accumulated curved-subpath vertices are turned into a `CurveArc`
/// by `flushPaintedPath` on a fill — the candidate geometry for ties.
private func captureCurve(_ s: State, endX: CGFloat?, endY: CGFloat?) {
    s.pendingPolyHasCurve = true
    if let endX, let endY {
        let end = CGPoint(x: endX, y: endY)
        s.currentPoint = end
        s.pendingPolyPoints.append(end)
    } else {
        s.currentPoint = nil
    }
}

private func op_fill(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.flushPaintedPath(fill: true)
}

private func op_stroke(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.flushPaintedPath(fill: false)
}

private func op_drop(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.resetPath()
}

// MARK: - Helpers

private func pageState(_ info: UnsafeMutableRawPointer?) -> State? {
    guard let info else { return nil }
    return Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
}

private func popNumber(_ scanner: CGPDFScannerRef) -> CGFloat? {
    var value: CGPDFReal = 0
    if CGPDFScannerPopNumber(scanner, &value) { return CGFloat(value) }
    var int: CGPDFInteger = 0
    if CGPDFScannerPopInteger(scanner, &int) { return CGFloat(int) }
    return nil
}

private func popName(_ scanner: CGPDFScannerRef) -> String? {
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return nil }
    return String(cString: name)
}

private func popString(_ scanner: CGPDFScannerRef) -> CGPDFStringRef? {
    var str: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &str), let str else { return nil }
    return str
}

private func popArray(_ scanner: CGPDFScannerRef) -> CGPDFArrayRef? {
    var arr: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &arr), let arr else { return nil }
    return arr
}

private func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
    // Operands pop off the stack in reverse order.
    guard let f = popNumber(scanner),
          let e = popNumber(scanner),
          let d = popNumber(scanner),
          let c = popNumber(scanner),
          let b = popNumber(scanner),
          let a = popNumber(scanner) else { return nil }
    return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
}
