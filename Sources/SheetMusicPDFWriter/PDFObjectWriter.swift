import SheetMusicFoundation

/// Writes a PDF file object by object, then the cross-reference table that finds them and the trailer. Numbers are
/// handed out first (`reserve`) so objects can name each other before they are written; every reserved number has to
/// be written before `finish`.
final class PDFObjectWriter: PDFObjectSink {
    private var bytes: [UInt8]
    private var offsets: [Int?] = []

    init() {
        // The binary comment line marks the file as binary for transfer tools that look (ISO 32000-1 §7.5.2).
        bytes = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
    }

    /// The next object number.
    func reserve() -> Int {
        offsets.append(nil)
        return offsets.count
    }

    /// Writes object `number` as `body` — a dictionary, an array, any direct object.
    func object(_ number: Int, _ body: String) {
        begin(number)
        append("\(body)\nendobj\n")
    }

    /// Writes object `number` as a stream: `dictionary`'s entries (without the `<< >>`) plus `/Length`, and with
    /// `compress` `/Filter /FlateDecode`, over `data`.
    func stream(_ number: Int, dictionary: String, data: Data, compress: Bool) throws {
        begin(number)
        bytes += try Self.streamBody(dictionary: dictionary, data: data, compress: compress)
        append("endobj\n")
    }

    /// A stream object's body after its `N G obj` line: `dictionary`'s entries plus `/Length` (and with `compress`
    /// `/Filter /FlateDecode`), then the payload. Shared with `PDFIncrementalWriter`.
    static func streamBody(dictionary: String, data: Data, compress: Bool) throws -> [UInt8] {
        let payload = compress ? try FlateStream.encode(data) : data
        let filter = compress ? " /Filter /FlateDecode" : ""
        let entries = dictionary.isEmpty ? "" : "\(dictionary) "
        return Array("<< \(entries)/Length \(payload.count)\(filter) >>\nstream\n".utf8) + payload
            + Array("\nendstream\n".utf8)
    }

    /// The file: every object, the cross-reference table, and a trailer naming `root` (the catalog) and `info`.
    func finish(root: Int, info: Int?) -> Data {
        precondition(!offsets.contains(nil), "every reserved object is written before the file is finished")
        let table = bytes.count
        append("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for case let offset? in offsets {
            append(Self.tenDigits(offset) + " 00000 n \n")
        }
        let infoEntry = info.map { " /Info \($0) 0 R" } ?? ""
        append("trailer\n<< /Size \(offsets.count + 1) /Root \(root) 0 R\(infoEntry) >>\nstartxref\n\(table)\n%%EOF\n")
        return Data(bytes)
    }

    private func begin(_ number: Int) {
        precondition(offsets.indices.contains(number - 1), "object \(number) was not reserved")
        offsets[number - 1] = bytes.count
        append("\(number) 0 obj\n")
    }

    private func append(_ text: String) {
        bytes += Array(text.utf8)
    }

    /// A byte offset as the cross-reference table writes it: ten digits, zero-padded.
    private static func tenDigits(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    }
}

/// PDF strings for the text a writer puts in a dictionary (a title, a font's name in a `ToUnicode` map).
enum PDFString {
    /// A text string (ISO 32000-1 §7.9.2.2): a literal `( … )` with `(`, `)` and `\` escaped when every character is
    /// printable ASCII, else UTF-16BE behind a byte-order mark as a hex string — the form any reader decodes for any
    /// script.
    static func text(_ string: String) -> String {
        if string.unicodeScalars.allSatisfy({ (0x20 ..< 0x7F).contains($0.value) }) {
            var escaped = ""
            for character in string {
                if character == "(" || character == ")" || character == "\\" { escaped.append("\\") }
                escaped.append(character)
            }
            return "(\(escaped))"
        }
        return "<FEFF" + string.utf16.map(hex4).joined() + ">"
    }

    /// A UTF-16 code unit as four hex digits.
    static func hex4(_ unit: UInt16) -> String {
        let digits = String(unit, radix: 16, uppercase: true)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }
}
