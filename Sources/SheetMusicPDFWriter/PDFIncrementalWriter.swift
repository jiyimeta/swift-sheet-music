import SheetMusicFoundation

/// Appended objects and their cross-references. Original objects are never modified in place.
final class PDFIncrementalWriter: PDFObjectSink {
    private var bytes: [UInt8]
    private var next: Int
    private var exhausted = false
    private var written: [Int: (offset: Int, generation: Int)] = [:]

    var hasObjects: Bool {
        !written.isEmpty
    }

    init(original: Data, nextNumber: Int) {
        bytes = Array(original)
        if let last = bytes.last, last != 10, last != 13 { bytes.append(10) }
        next = nextNumber
    }

    func reserve() -> Int {
        guard next < Int.max else {
            exhausted = true
            return next
        }
        defer { next += 1 }
        return next
    }

    func object(_ number: Int, _ body: String) {
        rewrite(number, generation: 0, body)
    }

    func stream(_ number: Int, dictionary: String, data: Data, compress: Bool) throws {
        guard !exhausted else { throw PDFAppendError.unreadable }
        begin(number, generation: 0)
        bytes += try PDFObjectWriter.streamBody(dictionary: dictionary, data: data, compress: compress)
        append("endobj\n")
    }

    func rewrite(_ number: Int, generation: Int, _ body: String) {
        begin(number, generation: generation)
        append("\(body)\nendobj\n")
    }

    /// Retains trailer identity and metadata while replacing section-local keys and linking `/Prev`.
    func finish(trailer: [String: PDFSourceValue], previous: Int, asStream: Bool) throws -> Data {
        guard !exhausted else { throw PDFAppendError.unreadable }
        let dropped: Set = [
            "Size",
            "Prev",
            "XRefStm",
            "Type",
            "W",
            "Index",
            "Length",
            "Filter",
            "DecodeParms",
            "F",
            "FFilter",
            "FDecodeParms",
            "DL",
        ]
        var carried = trailer.filter { !dropped.contains($0.key) }
        carried["Prev"] = .int(previous)
        if asStream {
            let number = reserve()
            guard !exhausted else { throw PDFAppendError.unreadable }
            let offset = bytes.count
            written[number] = (offset, 0)
            carried["Size"] = .int(next)
            carried["Type"] = .name("XRef")
            let width = offsetWidth()
            carried["W"] = .array([.int(1), .int(width), .int(2)])
            carried["Index"] = .array(subsections().flatMap { [PDFSourceValue.int($0.start), .int($0.count)] })
            var rows: [UInt8] = []
            for number in written.keys.sorted() {
                guard let entry = written[number] else { throw PDFAppendError.unreadable }
                rows.append(1)
                rows += bigEndian(entry.offset, width: width)
                rows += bigEndian(entry.generation, width: 2)
            }
            let dictionary = PDFSourceValue.dictionary(carried).serialized
            let entries = String(dictionary.dropFirst(3).dropLast(3))
            append("\(number) 0 obj\n")
            bytes += try PDFObjectWriter.streamBody(dictionary: entries, data: Data(rows), compress: true)
            append("endobj\nstartxref\n\(offset)\n%%EOF\n")
        } else {
            let table = bytes.count
            var text = "xref\n"
            for section in subsections() {
                text += "\(section.start) \(section.count)\n"
                for number in section.start ..< section.start + section.count {
                    guard let entry = written[number], let offset = UInt64(exactly: entry.offset),
                          offset <= 9_999_999_999
                    else {
                        throw PDFAppendError.unreadable
                    }
                    text += digits(entry.offset, width: 10) + " " + digits(entry.generation, width: 5) + " n \n"
                }
            }
            carried["Size"] = .int(next)
            text += "trailer\n\(PDFSourceValue.dictionary(carried).serialized)\nstartxref\n\(table)\n%%EOF\n"
            append(text)
        }
        return Data(bytes)
    }

    private func begin(_ number: Int, generation: Int) {
        if !(0 ... 65535).contains(generation) { exhausted = true }
        written[number] = (bytes.count, generation)
        append("\(number) \(generation) obj\n")
    }

    private func append(_ text: String) {
        bytes += Array(text.utf8)
    }

    private func subsections() -> [(start: Int, count: Int)] {
        var sections: [(start: Int, count: Int)] = []
        for number in written.keys.sorted() {
            if let last = sections.last, number - last.start == last.count {
                sections[sections.count - 1].count += 1
            } else { sections.append((number, 1)) }
        }
        return sections
    }

    private func offsetWidth() -> Int {
        var width = 4
        var largest = UInt64(written.values.map(\.offset).max() ?? 0)
        while largest > 0xFFFF_FFFF {
            width += 1
            largest >>= 8
        }
        return width
    }

    private func bigEndian(_ value: Int, width: Int) -> [UInt8] {
        (0 ..< width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func digits(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
