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

        // Painting operators that flush the in-progress path.
        CGPDFOperatorTableSetCallback(table, "S", op_flush)
        CGPDFOperatorTableSetCallback(table, "s", op_flush)
        CGPDFOperatorTableSetCallback(table, "f", op_flush)
        CGPDFOperatorTableSetCallback(table, "F", op_flush)
        CGPDFOperatorTableSetCallback(table, "f*", op_flush)
        CGPDFOperatorTableSetCallback(table, "B", op_flush)
        CGPDFOperatorTableSetCallback(table, "B*", op_flush)
        CGPDFOperatorTableSetCallback(table, "b", op_flush)
        CGPDFOperatorTableSetCallback(table, "b*", op_flush)

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

// swiftlint:disable identifier_name
private func op_Q(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    if s.ctmStack.count > 1 { s.ctmStack.removeLast() }
}

// swiftlint:enable identifier_name

private func op_cm(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let m = popMatrix(scanner) else { return }
    s.setTopCTM(m.concatenating(s.ctm))
}

private func op_w(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let v = popNumber(scanner) else { return }
    s.lineWidth = v
}

// swiftlint:disable identifier_name
private func op_BT(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    s.textMatrix = .identity
    s.lineMatrix = .identity
}

private func op_Tf(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    if let size = popNumber(scanner) { s.fontSize = size }
    if let name = popName(scanner) { s.fontName = name }
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
    emitText(decodeString(str), state: s)
}

private func op_TJ(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let arr = popArray(scanner) else { return }
    var combined = ""
    let count = CGPDFArrayGetCount(arr)
    for i in 0 ..< count {
        var str: CGPDFStringRef?
        if CGPDFArrayGetString(arr, i, &str), let str {
            combined += decodeString(str)
        }
        // Numbers are kerning offsets — ignored for our walker.
    }
    if !combined.isEmpty { emitText(combined, state: s) }
}

// swiftlint:enable identifier_name

private func op_quote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    s.textMatrix = s.lineMatrix
    emitText(decodeString(str), state: s)
}

private func op_dquote(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info), let str = popString(scanner) else { return }
    _ = popNumber(scanner) // word spacing
    _ = popNumber(scanner) // char spacing
    s.textMatrix = s.lineMatrix
    emitText(decodeString(str), state: s)
}

private func op_m(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info),
          let y = popNumber(scanner),
          let x = popNumber(scanner) else { return }
    s.currentPoint = CGPoint(x: x, y: y)
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
    for _ in 0 ..< 6 {
        _ = popNumber(scanner)
    }
    s.currentPoint = nil
}

private func op_v(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    for _ in 0 ..< 4 {
        _ = popNumber(scanner)
    }
    s.currentPoint = nil
}

private func op_y(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let s = pageState(info) else { return }
    for _ in 0 ..< 4 {
        _ = popNumber(scanner)
    }
    s.currentPoint = nil
}

private func op_flush(_: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    pageState(info)?.flushPaintedPath()
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

/// Decode a Tj/TJ string operand. Test fixtures use Helvetica with
/// ASCII bytes — treating them as UTF-8 is correct there. For
/// CID-encoded SMuFL fonts the upstream pipeline will apply the
/// `ToUnicodeCMap`; that path is exercised in Task 15's round-trip.
private func decodeString(_ str: CGPDFStringRef) -> String {
    let length = CGPDFStringGetLength(str)
    guard length > 0, let bytes = CGPDFStringGetBytePtr(str) else { return "" }
    // Test fixtures (Helvetica + ASCII) decode cleanly as UTF-8. Fall back
    // to a per-byte Latin-1 mapping for SMuFL CID payloads we can't yet
    // resolve through ToUnicodeCMap — keeps the walker total.
    let data = Data(bytes: bytes, count: length)
    if let utf8 = String(bytes: data, encoding: .utf8) { return utf8 }
    return String(bytes: data, encoding: .isoLatin1) ?? ""
}

/// Emit a `TextGlyph` for a decoded text run at the current text
/// origin in page coordinates, then advance the text matrix by an
/// approximate width so subsequent `Tj`s in the same run land
/// further right (tests don't pin advance precision).
private func emitText(_ text: String, state: State) {
    guard !text.isEmpty else { return }
    let originUserSpace = CGPoint.zero.applying(state.textMatrix)
    let originPageSpace = originUserSpace.applying(state.ctm)
    state.texts.append(TextGlyph(
        text: text,
        fontName: state.fontName,
        fontSize: state.fontSize,
        origin: originPageSpace,
        bbox: .zero,
        pageIndex: state.pageIndex,
    ))
    let approxAdvance = state.fontSize * 0.5 * CGFloat(text.count)
    state.textMatrix = CGAffineTransform(translationX: approxAdvance, y: 0)
        .concatenating(state.textMatrix)
}
