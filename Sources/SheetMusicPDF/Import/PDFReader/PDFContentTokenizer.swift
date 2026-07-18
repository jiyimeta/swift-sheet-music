#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

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
            case PDFBytes.slash:
                operands.append(.name(parseName(bytes, &pos)))
            case PDFBytes.lparen:
                operands.append(.string(parseLiteralString(bytes, &pos)))
            case PDFBytes.lt:
                if pos + 1 < count, bytes[pos + 1] == PDFBytes.lt {
                    skipDictionary(bytes, &pos) // BDC / DP marked content
                } else {
                    operands.append(.string(parseHexString(bytes, &pos)))
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
            case PDFBytes.lparen:
                items.append(.string(parseLiteralString(bytes, &pos)))
            case PDFBytes.lt:
                if pos + 1 < count, bytes[pos + 1] == PDFBytes.lt {
                    skipDictionary(bytes, &pos)
                } else {
                    items.append(.string(parseHexString(bytes, &pos)))
                }
            case PDFBytes.slash:
                items.append(.name(parseName(bytes, &pos)))
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

    private static func parseName(_ bytes: [UInt8], _ pos: inout Int) -> String {
        pos += 1 // '/'
        var out = [UInt8]()
        let count = bytes.count
        while pos < count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) || PDFBytes.isDelimiter(c) {
                break
            }
            if c == PDFBytes.hash, pos + 2 < count,
               let hi = PDFBytes.hexValue(bytes[pos + 1]),
               let lo = PDFBytes.hexValue(bytes[pos + 2])
            {
                out.append(UInt8(hi * 16 + lo))
                pos += 3
                continue
            }
            out.append(c)
            pos += 1
        }
        return PDFBytes.string(out)
    }

    private static func parseLiteralString(_ bytes: [UInt8], _ pos: inout Int) -> [UInt8] {
        pos += 1 // '('
        var out = [UInt8]()
        var depth = 1
        let count = bytes.count
        while pos < count {
            let c = bytes[pos]
            pos += 1
            if c == PDFBytes.backslash {
                appendEscape(bytes, &pos, into: &out)
            } else if c == PDFBytes.lparen {
                depth += 1
                out.append(c)
            } else if c == PDFBytes.rparen {
                depth -= 1
                if depth == 0 {
                    break
                }
                out.append(c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func appendEscape(_ bytes: [UInt8], _ pos: inout Int, into out: inout [UInt8]) {
        guard pos < bytes.count else {
            return
        }
        let e = bytes[pos]
        pos += 1
        switch e {
        case 0x6E: out.append(PDFBytes.lineFeed) // \n
        case 0x72: out.append(PDFBytes.carriageReturn) // \r
        case 0x74: out.append(PDFBytes.tab) // \t
        case 0x62: out.append(0x08) // \b
        case 0x66: out.append(PDFBytes.formFeed) // \f
        case PDFBytes.lparen: out.append(PDFBytes.lparen)
        case PDFBytes.rparen: out.append(PDFBytes.rparen)
        case PDFBytes.backslash: out.append(PDFBytes.backslash)
        case PDFBytes.lineFeed: break // line continuation
        case PDFBytes.carriageReturn:
            if pos < bytes.count, bytes[pos] == PDFBytes.lineFeed { pos += 1 }
        case 0x30 ... 0x37:
            var value = Int(e - 0x30)
            var n = 1
            while n < 3, pos < bytes.count, PDFBytes.isOctalDigit(bytes[pos]) {
                value = value * 8 + Int(bytes[pos] - 0x30)
                pos += 1
                n += 1
            }
            out.append(UInt8(value & 0xFF))
        default:
            out.append(e)
        }
    }

    private static func parseHexString(_ bytes: [UInt8], _ pos: inout Int) -> [UInt8] {
        pos += 1 // '<'
        var nibbles = [Int]()
        let count = bytes.count
        while pos < count {
            let c = bytes[pos]
            pos += 1
            if c == PDFBytes.gt {
                break
            }
            if let v = PDFBytes.hexValue(c) {
                nibbles.append(v)
            }
        }
        if nibbles.count % 2 == 1 {
            nibbles.append(0)
        }
        var out = [UInt8]()
        out.reserveCapacity(nibbles.count / 2)
        var i = 0
        while i < nibbles.count {
            out.append(UInt8((nibbles[i] << 4) | nibbles[i + 1]))
            i += 2
        }
        return out
    }

    // MARK: - Cursor helpers

    private static func readRegularRun(_ bytes: [UInt8], _ pos: inout Int) -> String {
        var out = [UInt8]()
        while pos < bytes.count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) || PDFBytes.isDelimiter(c) {
                break
            }
            out.append(c)
            pos += 1
        }
        return PDFBytes.string(out)
    }

    private static func skipWhitespaceAndComments(_ bytes: [UInt8], _ pos: inout Int) {
        while pos < bytes.count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) {
                pos += 1
            } else if c == PDFBytes.percent {
                while pos < bytes.count,
                      bytes[pos] != PDFBytes.lineFeed,
                      bytes[pos] != PDFBytes.carriageReturn
                {
                    pos += 1
                }
            } else {
                break
            }
        }
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
            } else if c == PDFBytes.lparen {
                _ = parseLiteralString(bytes, &pos)
            } else if c == PDFBytes.lt {
                _ = parseHexString(bytes, &pos)
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
