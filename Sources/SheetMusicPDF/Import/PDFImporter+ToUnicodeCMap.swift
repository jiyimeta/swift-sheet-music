#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension PDFImporter {
    /// CID → Unicode lookup parsed from a Type0 font's `/ToUnicode`
    /// CMap stream (PDF 32000-1 §9.10.3). MuseScore exports map each
    /// glyph CID to its SMuFL PUA codepoint (Leland / LelandText) or to
    /// ordinary Unicode (Edwin text). Identity-H fonts use 2-byte CIDs.
    ///
    /// Supported CMap constructs:
    ///   - `beginbfchar` / `endbfchar`:   `<src> <dst>`
    ///   - `beginbfrange` / `endbfrange`, two destination forms:
    ///       * contiguous:  `<srcLo> <srcHi> <dstLo>`  (dst increments)
    ///       * array:       `<srcLo> <srcHi> [ <d0> <d1> … ]` (index in)
    ///   - the `<0000> <0000> <0000>` notdef self-map row.
    ///
    /// A destination may be a multi-scalar UTF-16BE sequence (e.g.
    /// `<0066006C>` → "fl"). The full sequence is decoded; PUA routing
    /// tests the FIRST scalar.
    struct ToUnicodeCMap {
        /// CID → decoded Unicode scalar sequence. Empty sequences are
        /// not stored.
        private let table: [UInt32: [Unicode.Scalar]]

        init(table: [UInt32: [Unicode.Scalar]]) {
            self.table = table
        }

        /// First decoded scalar for `cid`, or nil if unmapped.
        func firstScalar(cid: UInt32) -> Unicode.Scalar? {
            table[cid]?.first
        }

        /// Full decoded scalar sequence for `cid`, or nil if unmapped.
        func scalars(cid: UInt32) -> [Unicode.Scalar]? {
            table[cid]
        }

        var isEmpty: Bool {
            table.isEmpty
        }

        // MARK: - Parsing

        /// Parse a plaintext (already FlateDecode-inflated) ToUnicode
        /// CMap. `data` is interpreted as ISO-Latin-1 text per the PDF
        /// CMap convention.
        static func parse(data: Data) -> ToUnicodeCMap {
            // PDF CMaps are ISO-Latin-1 text; the hex destinations inside
            // <...> are the real payload, so a 1:1 byte→scalar decode is safe.
            let text = String(data: data, encoding: .isoLatin1) ?? ""
            let tokens = tokenize(text)
            var table: [UInt32: [Unicode.Scalar]] = [:]
            var i = 0
            while i < tokens.count {
                switch tokens[i] {
                case .keyword("beginbfchar"):
                    i = parseBFChar(tokens, from: i + 1, into: &table)
                case .keyword("beginbfrange"):
                    i = parseBFRange(tokens, from: i + 1, into: &table)
                default:
                    i += 1
                }
            }
            return ToUnicodeCMap(table: table)
        }

        // MARK: - bfchar / bfrange

        /// Parse `<src> <dst>` rows until `endbfchar`. Returns the index
        /// just past the terminator.
        private static func parseBFChar(
            _ tokens: [Token], from start: Int,
            into table: inout [UInt32: [Unicode.Scalar]],
        ) -> Int {
            var i = start
            while i < tokens.count {
                if case .keyword("endbfchar") = tokens[i] { return i + 1 }
                guard case let .hex(srcBytes) = tokens[i],
                      i + 1 < tokens.count,
                      case let .hex(dstBytes) = tokens[i + 1]
                else { i += 1; continue }
                let cid = bytesToCID(srcBytes)
                let scalars = utf16BEScalars(dstBytes)
                if !scalars.isEmpty { table[cid] = scalars }
                i += 2
            }
            return i
        }

        /// Parse the two `bfrange` destination forms until `endbfrange`.
        private static func parseBFRange(
            _ tokens: [Token], from start: Int,
            into table: inout [UInt32: [Unicode.Scalar]],
        ) -> Int {
            var i = start
            while i < tokens.count {
                if case .keyword("endbfrange") = tokens[i] { return i + 1 }
                guard case let .hex(loBytes) = tokens[i],
                      i + 1 < tokens.count,
                      case let .hex(hiBytes) = tokens[i + 1]
                else { i += 1; continue }
                let lo = bytesToCID(loBytes)
                let hi = bytesToCID(hiBytes)
                i = applyRange(tokens, after: i + 2, lo: lo, hi: hi, into: &table)
            }
            return i
        }

        /// Consume the destination after a `<lo> <hi>` pair — either an
        /// array `[ … ]` (index per CID) or a single contiguous `<dstLo>`
        /// (increment per CID). Returns the index just past the dest.
        private static func applyRange(
            _ tokens: [Token], after destStart: Int,
            lo: UInt32, hi: UInt32,
            into table: inout [UInt32: [Unicode.Scalar]],
        ) -> Int {
            guard destStart < tokens.count, lo <= hi else { return destStart }
            switch tokens[destStart] {
            case .arrayOpen:
                var j = destStart + 1
                var offset: UInt32 = 0
                while j < tokens.count {
                    if case .arrayClose = tokens[j] { return j + 1 }
                    if case let .hex(dstBytes) = tokens[j] {
                        let cid = lo &+ offset
                        if cid <= hi {
                            let scalars = utf16BEScalars(dstBytes)
                            if !scalars.isEmpty { table[cid] = scalars }
                        }
                        offset &+= 1
                    }
                    j += 1
                }
                return j
            case let .hex(dstBytes):
                // Contiguous: dst increments alongside src. Only the
                // last scalar increments (per PDF spec); for the common
                // single-scalar case that's exactly dst + i.
                let base = utf16BEScalars(dstBytes)
                guard let lastValue = base.last?.value else { return destStart + 1 }
                let prefix = base.dropLast()
                var cid = lo
                var step: UInt32 = 0
                while cid <= hi {
                    let scalarValue = lastValue &+ step
                    if let scalar = Unicode.Scalar(scalarValue) {
                        table[cid] = Array(prefix) + [scalar]
                    }
                    if cid == hi { break } // avoid UInt32 overflow at 0xFFFF
                    cid &+= 1
                    step &+= 1
                }
                return destStart + 1
            default:
                return destStart
            }
        }

        // MARK: - Byte helpers

        /// Interpret 1–2 source bytes as a big-endian CID. Identity-H
        /// uses 2 bytes; we also accept 1-byte sources defensively.
        private static func bytesToCID(_ bytes: [UInt8]) -> UInt32 {
            var value: UInt32 = 0
            for b in bytes {
                value = (value << 8) | UInt32(b)
            }
            return value
        }

        /// Decode a UTF-16BE byte sequence (the CMap destination form)
        /// into Unicode scalars, handling surrogate pairs.
        private static func utf16BEScalars(_ bytes: [UInt8]) -> [Unicode.Scalar] {
            var units: [UInt16] = []
            var i = 0
            while i + 1 < bytes.count {
                units.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
                i += 2
            }
            if i < bytes.count { units.append(UInt16(bytes[i])) }
            var scalars: [Unicode.Scalar] = []
            var decoder = UTF16()
            var iterator = units.makeIterator()
            decode: while true {
                switch decoder.decode(&iterator) {
                case let .scalarValue(s): scalars.append(s)
                case .emptyInput: break decode
                case .error:
                    // Lone surrogate / malformed: fall back to raw units
                    // as scalars where representable.
                    break decode
                }
            }
            if scalars.isEmpty {
                for u in units {
                    if let scalar = Unicode.Scalar(u) { scalars.append(scalar) }
                }
            }
            return scalars
        }

        // MARK: - Tokenizer

        enum Token: Equatable {
            case hex([UInt8]) // contents of <...>
            case arrayOpen
            case arrayClose
            case keyword(String) // begin*/end*/other bare words
            case number // numeric token (range counts etc.) — ignored
        }

        /// Tokenize CMap text into `<...>` hex strings, `[`, `]`, and
        /// bare keywords. Numbers and PostScript noise are coalesced into
        /// `.number` / `.keyword` and largely ignored downstream.
        static func tokenize(_ text: String) -> [Token] {
            var tokens: [Token] = []
            let scalars = Array(text.unicodeScalars)
            var i = 0
            while i < scalars.count {
                let c = scalars[i]
                if c == "<" {
                    var j = i + 1
                    var hexChars = ""
                    while j < scalars.count, scalars[j] != ">" {
                        hexChars.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    tokens.append(.hex(hexStringToBytes(hexChars)))
                    i = j + 1
                } else if c == "[" {
                    tokens.append(.arrayOpen); i += 1
                } else if c == "]" {
                    tokens.append(.arrayClose); i += 1
                } else if isWhitespace(c) {
                    i += 1
                } else if c == "(" || c == ")" || c == "/" || c == "{" || c == "}" {
                    // Skip PostScript literal-name / proc syntax markers;
                    // names are consumed up to the next delimiter below.
                    i += 1
                } else {
                    var j = i
                    var word = ""
                    while j < scalars.count,
                          !isWhitespace(scalars[j]),
                          !isDelimiter(scalars[j])
                    {
                        word.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    if word.isEmpty {
                        i += 1
                    } else if word.unicodeScalars.allSatisfy({
                        ("0" ... "9").contains($0)
                            || $0 == "." || $0 == "-" || $0 == "+"
                    }) {
                        tokens.append(.number); i = j
                    } else {
                        tokens.append(.keyword(word)); i = j
                    }
                }
            }
            return tokens
        }

        private static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
            c == " " || c == "\n" || c == "\r" || c == "\t" || c.value == 0 || c.value == 0x0C
        }

        private static func isDelimiter(_ c: Unicode.Scalar) -> Bool {
            c == "<" || c == ">" || c == "[" || c == "]"
                || c == "(" || c == ")" || c == "/" || c == "{" || c == "}"
        }

        private static func hexStringToBytes(_ s: String) -> [UInt8] {
            var bytes: [UInt8] = []
            var hi: UInt8?
            for c in s.unicodeScalars {
                guard let nibble = hexNibble(c) else { continue }
                if let h = hi {
                    bytes.append((h << 4) | nibble)
                    hi = nil
                } else {
                    hi = nibble
                }
            }
            if let h = hi { bytes.append(h << 4) } // odd-length: pad low nibble
            return bytes
        }

        private static func hexNibble(_ c: Unicode.Scalar) -> UInt8? {
            switch c {
            case "0" ... "9": return UInt8(c.value - 48)
            case "a" ... "f": return UInt8(c.value - 97 + 10)
            case "A" ... "F": return UInt8(c.value - 65 + 10)
            default: return nil
            }
        }
    }
}
