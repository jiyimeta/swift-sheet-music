import Foundation
@testable import SheetMusicPDFWriter

/// PDFs assembled independently of the reader, including compressed page-tree objects.
enum PDFFixtures {
    struct Page {
        var mediaBox = "[0 0 612 792]"
        var extra = ""
        var annots: Annots = .none
    }

    enum Annots { case none, direct, indirect }
    enum Shape { case classic, objectStreams }

    static func make(_ pages: [Page], shape: Shape = .classic, trailerExtra: String = "") -> Data {
        var objects: [(number: Int, body: String, compressible: Bool)] = []
        var kids: [Int] = []
        var next = 3
        for page in pages {
            let number = next
            let contents = next + 1
            next += 2
            var annots = ""
            switch page.annots {
            case .none: break
            case .direct:
                annots = " /Annots [\(next) 0 R]"
                objects.append((next, "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] >>", true))
                next += 1
            case .indirect:
                annots = " /Annots \(next) 0 R"
                objects.append((next, "[\(next + 1) 0 R]", true))
                objects.append((next + 1, "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] >>", true))
                next += 2
            }
            objects.append((
                number,
                "<< /Type /Page /Parent 2 0 R /MediaBox \(page.mediaBox)"
                    + "\(page.extra) /Contents \(contents) 0 R\(annots) >>",
                true,
            ))
            objects.append((contents, "STREAM:0 0 m 10 10 l S", false))
            kids.append(number)
        }
        objects.append((1, "<< /Type /Catalog /Pages 2 0 R >>", true))
        objects.append((
            2,
            "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))]"
                + " /Count \(kids.count) >>",
            true,
        ))
        objects.sort { $0.number < $1.number }
        if shape == .classic { return classic(objects, size: next, trailerExtra: trailerExtra) }
        return compressed(objects, size: next, trailerExtra: trailerExtra)
    }

    private static func classic(
        _ objects: [(number: Int, body: String, compressible: Bool)],
        size: Int,
        trailerExtra: String,
    ) -> Data {
        var bytes = Array("%PDF-1.4\n".utf8)
        var offsets = [Int](repeating: 0, count: size)
        for object in objects {
            offsets[object.number] = bytes.count
            bytes += Array("\(object.number) 0 obj\n".utf8)
            if object.body.hasPrefix("STREAM:") {
                let data = Data(object.body.dropFirst(7).utf8)
                bytes += streamBody(dictionary: "", data: data, compress: false)
            } else { bytes += Array("\(object.body)\n".utf8) }
            bytes += Array("endobj\n".utf8)
        }
        let start = bytes.count
        bytes += Array("xref\n0 \(size)\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            bytes += Array("\(digits(offset)) 00000 n \n".utf8)
        }
        bytes += Array("trailer\n<< /Size \(size) /Root 1 0 R\(trailerExtra) >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return Data(bytes)
    }

    private static func compressed(
        _ objects: [(number: Int, body: String, compressible: Bool)],
        size: Int,
        trailerExtra: String,
    ) -> Data {
        var bytes = Array("%PDF-1.5\n".utf8)
        var entries = [(Int, Int, Int)](repeating: (0, 0, 0), count: size + 2)
        entries[0] = (0, 0, 65535)
        var bodies = [UInt8]()
        var header = ""
        let packed = objects.filter(\.compressible)
        for (index, object) in packed.enumerated() {
            header += "\(object.number) \(bodies.count) "
            bodies += Array("\(object.body) ".utf8)
            entries[object.number] = (2, size, index)
        }
        for object in objects where !object.compressible {
            entries[object.number] = (1, bytes.count, 0)
            bytes += Array("\(object.number) 0 obj\n".utf8)
            bytes += streamBody(
                dictionary: "",
                data: Data(object.body.dropFirst(7).utf8),
                compress: false,
            )
            bytes += Array("endobj\n".utf8)
        }
        entries[size] = (1, bytes.count, 0)
        bytes += Array("\(size) 0 obj\n".utf8)
        bytes += streamBody(
            dictionary: "/Type /ObjStm /N \(packed.count) /First \(header.utf8.count)",
            data: Data(Array(header.utf8) + bodies), compress: true,
        )
        bytes += Array("endobj\n".utf8)
        let start = bytes.count
        entries[size + 1] = (1, start, 0)
        var previous = [UInt8](repeating: 0, count: 5)
        var predicted = [UInt8]()
        for (type, field, last) in entries {
            let row = [
                UInt8(type),
                UInt8(truncatingIfNeeded: field >> 8),
                UInt8(truncatingIfNeeded: field),
                UInt8(truncatingIfNeeded: last >> 8),
                UInt8(truncatingIfNeeded: last),
            ]
            predicted.append(2)
            predicted += zip(row, previous).map { $0 &- $1 }
            previous = row
        }
        bytes += Array("\(size + 1) 0 obj\n".utf8)
        bytes += streamBody(
            dictionary: "/Type /XRef /Size \(size + 2) /Root 1 0 R /W [1 2 2]"
                + " /DecodeParms << /Predictor 12 /Columns 5 >>\(trailerExtra)",
            data: Data(predicted), compress: true,
        )
        bytes += Array("endobj\nstartxref\n\(start)\n%%EOF\n".utf8)
        return Data(bytes)
    }

    static func updated(_ original: Data, redefining number: Int, as body: String) -> Data {
        let text = String(bytes: original, encoding: .isoLatin1) ?? ""
        guard let newest = text.components(separatedBy: "startxref\n").last,
              let sizeEntry = text.components(separatedBy: "/Size ").last,
              let size = Int(sizeEntry.components(separatedBy: " ")[0])
        else {
            preconditionFailure("invalid PDF fixture")
        }
        let previous = newest.components(separatedBy: "\n")[0]
        var bytes = [UInt8](original)
        let offset = bytes.count
        bytes += Array("\(number) 0 obj\n\(body)\nendobj\n".utf8)
        let start = bytes.count
        bytes += Array("xref\n\(number) 1\n\(digits(offset)) 00000 n \ntrailer\n".utf8)
        bytes += Array(("<< /Size \(max(size, number + 1)) /Root 1 0 R /Prev \(previous) >>\n"
                + "startxref\n\(start)\n%%EOF\n").utf8)
        return Data(bytes)
    }

    private static func streamBody(dictionary: String, data: Data, compress: Bool) -> [UInt8] {
        do {
            return try PDFObjectWriter.streamBody(dictionary: dictionary, data: data, compress: compress)
        } catch {
            preconditionFailure("cannot encode PDF fixture: \(error)")
        }
    }

    private static func digits(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 10 - text.count)) + text
    }
}
