#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicPDFSyntax

/// An operand in a page content stream.
enum PDFOperand: Equatable {
    case number(CGFloat)
    /// A name, without the leading slash.
    case name(String)
    case string([UInt8])
    /// An operand array (as used by `TJ`).
    case array([PDFOperand])
}

/// A content-stream operator with the operands that preceded it, in stream
/// (forward) order.
struct PDFContentOp {
    let op: String
    let operands: [PDFOperand]
}

/// Tokenizer for an inflated page content stream.
///
/// Operands accumulate until a bare operator keyword flushes them (unknown
/// operators flush too, so operand stacks never leak across operators).
/// `BDC` / `DP` marked-content dictionaries are parsed-and-discarded; inline
/// images (`BI … ID … EI`) are skipped (MuseScore PDFs contain none).
///
/// Names, strings and the whitespace between tokens are read by the object parser the rest of the reader uses, so a
/// name here — a font's resource key in `Tf` — is the same string as that key in the page's `/Font` dictionary.
enum PDFContentTokenizer {
    static func tokenize(_ bytes: [UInt8]) -> [PDFContentOp] {
        var ops = [PDFContentOp]()
        var operands = [PDFOperand]()
        var pos = 0
        let count = bytes.count
        while pos < count {
            skipWhitespaceAndComments(bytes, &pos)
            guard pos < count else {
                break
            }
            let c = bytes[pos]
            switch c {
            case PDFBytes.slash, PDFBytes.lparen:
                if let operand = scalar(bytes, &pos) {
                    operands.append(operand)
                }
            case PDFBytes.lt:
                if pos + 1 < count, bytes[pos + 1] == PDFBytes.lt {
                    skipDictionary(bytes, &pos) // BDC / DP marked content
                } else if let operand = scalar(bytes, &pos) {
                    operands.append(operand)
                }
            case PDFBytes.lbracket:
                operands.append(.array(parseOperandArray(bytes, &pos)))
            case PDFBytes.rbracket, PDFBytes.gt, PDFBytes.rparen, PDFBytes.lbrace, PDFBytes.rbrace:
                pos += 1 // stray delimiter
            default:
                if PDFBytes.isNumberStart(c) {
                    operands.append(.number(parseNumber(bytes, &pos)))
                } else {
                    let keyword = readRegularRun(bytes, &pos)
                    if keyword.isEmpty {
                        pos += 1
                    } else if keyword == "BI" {
                        skipInlineImage(bytes, &pos)
                        operands.removeAll()
                    } else {
                        ops.append(PDFContentOp(op: keyword, operands: operands))
                        operands.removeAll()
                    }
                }
            }
        }
        return ops
    }

    // MARK: - Operand parsers

    private static func parseOperandArray(_ bytes: [UInt8], _ pos: inout Int) -> [PDFOperand] {
        pos += 1 // '['
        var items = [PDFOperand]()
        let count = bytes.count
        while pos < count {
            skipWhitespaceAndComments(bytes, &pos)
            guard pos < count else {
                break
            }
            let c = bytes[pos]
            switch c {
            case PDFBytes.rbracket:
                pos += 1
                return items
            case PDFBytes.lt:
                if pos + 1 < count, bytes[pos + 1] == PDFBytes.lt {
                    skipDictionary(bytes, &pos)
                } else if let operand = scalar(bytes, &pos) {
                    items.append(operand)
                }
            case PDFBytes.lparen, PDFBytes.slash:
                if let operand = scalar(bytes, &pos) {
                    items.append(operand)
                }
            case PDFBytes.lbracket:
                items.append(.array(parseOperandArray(bytes, &pos)))
            default:
                if PDFBytes.isNumberStart(c) {
                    items.append(.number(parseNumber(bytes, &pos)))
                } else if readRegularRun(bytes, &pos).isEmpty {
                    pos += 1 // stray delimiter
                }
            }
        }
        return items
    }

    private static func parseNumber(_ bytes: [UInt8], _ pos: inout Int) -> CGFloat {
        let token = readRegularRun(bytes, &pos)
        return CGFloat(Double(token) ?? 0)
    }

    /// The name, literal string or hex string at `pos`, read by the object parser; `pos` moves past it.
    private static func scalar(_ bytes: [UInt8], _ pos: inout Int) -> PDFOperand? {
        var parser = PDFObjectParser(bytes, at: pos, lenient: true)
        let value = parser.parseValue()
        pos = max(parser.pos, pos + 1)
        switch value {
        case let .name(name): return .name(name)
        case let .string(string): return .string(string)
        default: return nil
        }
    }

    // MARK: - Cursor helpers

    private static func readRegularRun(_ bytes: [UInt8], _ pos: inout Int) -> String {
        var parser = PDFObjectParser(bytes, at: pos)
        let token = parser.token()
        pos = parser.pos
        return token
    }

    private static func skipWhitespaceAndComments(_ bytes: [UInt8], _ pos: inout Int) {
        var parser = PDFObjectParser(bytes, at: pos)
        parser.skipWhitespaceAndComments()
        pos = parser.pos
    }

    /// Skip a `<< … >>` dictionary (nested-aware; literal/hex strings are
    /// consumed so stray `>` inside them don't unbalance the scan).
    private static func skipDictionary(_ bytes: [UInt8], _ pos: inout Int) {
        let count = bytes.count
        pos += 2 // '<<'
        var depth = 1
        while pos < count, depth > 0 {
            let c = bytes[pos]
            if c == PDFBytes.lt, pos + 1 < count, bytes[pos + 1] == PDFBytes.lt {
                depth += 1
                pos += 2
            } else if c == PDFBytes.gt, pos + 1 < count, bytes[pos + 1] == PDFBytes.gt {
                depth -= 1
                pos += 2
            } else if c == PDFBytes.lparen || c == PDFBytes.lt {
                _ = scalar(bytes, &pos)
            } else {
                pos += 1
            }
        }
    }

    /// Skip an inline image to just past the terminating `EI` token.
    private static func skipInlineImage(_ bytes: [UInt8], _ pos: inout Int) {
        let count = bytes.count
        var i = pos
        while i + 1 < count {
            if bytes[i] == 0x45, bytes[i + 1] == 0x49 { // "EI"
                let beforeOK = i == 0 || PDFBytes.isWhitespace(bytes[i - 1])
                let afterIdx = i + 2
                let afterOK = afterIdx >= count
                    || PDFBytes.isWhitespace(bytes[afterIdx]) || PDFBytes.isDelimiter(bytes[afterIdx])
                if beforeOK, afterOK {
                    pos = afterIdx
                    return
                }
            }
            i += 1
        }
        pos = count
    }
}
