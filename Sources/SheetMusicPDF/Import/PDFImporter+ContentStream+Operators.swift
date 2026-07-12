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
    pageState(info)?.opPushGraphicsState()
}

private func op_Q(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opPopGraphicsState()
}

private func op_cm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let m = popMatrix(scanner) else { return }
    s.opConcatCTM(m)
}

private func op_w(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let v = popNumber(scanner) else { return }
    s.opSetLineWidth(v)
}

private func op_BT(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opBeginText()
}

private func op_Tf(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    // Pop order matches `/Font size Tf`: the size is on top, then the name.
    // Both pops run unconditionally (as before); nil leaves that field as-is.
    let size = popNumber(scanner)
    let name = popName(scanner)
    s.opSetFont(name: name, size: size)
}

private func op_Tm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let m = popMatrix(scanner) else { return }
    s.opSetTextMatrix(m)
}

private func op_Td(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let ty = popNumber(scanner),
          let tx = popNumber(scanner) else { return }
    s.opTextMove(tx: tx, ty: ty)
}

private func op_TD(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    op_Td(scanner, info)
}

private func op_Tstar(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opTextNextLine()
}

private func op_Tj(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    s.opShow(stringBytes(str))
}

private func op_TJ(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let arr = popArray(scanner) else { return }
    let count = CGPDFArrayGetCount(arr)
    for i in 0 ..< count {
        var str: CGPDFStringRef?
        if CGPDFArrayGetString(arr, i, &str), let str {
            s.opShow(stringBytes(str))
        }
        // Numbers are kerning offsets — ignored for our walker.
    }
}

private func op_quote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    s.opShowNextLine(stringBytes(str))
}

private func op_dquote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    _ = popNumber(scanner) // word spacing
    _ = popNumber(scanner) // char spacing
    s.opShowNextLine(stringBytes(str))
}

private func op_m(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    s.opMoveTo(x: x, y: y)
}

private func op_l(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    s.opLineTo(x: x, y: y)
}

private func op_re(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let h = popNumber(scanner),
          let w = popNumber(scanner),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    s.opAppendRect(x: x, y: y, width: w, height: h)
}

private func op_c(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 6 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    // Operands pop in reverse; the cubic's endpoint is the first pair shown
    // in the stream → the last two values popped (nums[5], nums[4]).
    s.opCurve(endX: nums.count == 6 ? nums[5] : nil, endY: nums.count == 6 ? nums[4] : nil)
}

private func op_v(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 4 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    s.opCurve(endX: nums.count == 4 ? nums[3] : nil, endY: nums.count == 4 ? nums[2] : nil)
}

private func op_y(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    var nums: [CGFloat] = []
    for _ in 0 ..< 4 {
        if let n = popNumber(scanner) { nums.append(n) }
    }
    s.opCurve(endX: nums.count == 4 ? nums[3] : nil, endY: nums.count == 4 ? nums[2] : nil)
}

private func op_fill(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opFill()
}

private func op_stroke(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opStroke()
}

private func op_drop(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.opEndPath()
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

/// Copy a `CGPDFStringRef`'s raw bytes into a platform-neutral `[UInt8]`.
/// The interpreter's text-show core (`emitShow`) consumes bytes, not a
/// CoreGraphics string handle, so the same core drives the future Android
/// tokenizer front-end unchanged.
private func stringBytes(_ str: CGPDFStringRef) -> [UInt8] {
    let length = CGPDFStringGetLength(str)
    guard length > 0, let ptr = CGPDFStringGetBytePtr(str) else { return [] }
    return Array(UnsafeBufferPointer(start: ptr, count: length))
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
