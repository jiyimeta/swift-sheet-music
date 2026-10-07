import SheetMusicFoundation

extension PDFSourceDocument {
    static func rawStream(_ bytes: [UInt8], parser: inout PDFSourceParser, length: Int?) throws -> [UInt8] {
        // The stream keyword is followed by LF or CRLF, not arbitrary whitespace (the payload may start with it).
        if parser.pos < bytes.count, bytes[parser.pos] == 13 { parser.pos += 1 }
        guard parser.pos < bytes.count, bytes[parser.pos] == 10 else { throw PDFAppendError.unreadable }
        parser.pos += 1
        let start = parser.pos
        if let length, length >= 0, length <= bytes.count - start {
            var end = PDFSourceParser(bytes, at: start + length)
            if end.token() == "endstream" { return Array(bytes[start ..< start + length]) }
        }
        guard let end = find(Array("endstream".utf8), in: bytes, from: start) else { throw PDFAppendError.unreadable }
        var stop = end
        if stop > start, bytes[stop - 1] == 10 { stop -= 1 }
        if stop > start, bytes[stop - 1] == 13 { stop -= 1 }
        return Array(bytes[start ..< stop])
    }

    static func decode(_ raw: [UInt8], dictionary: [String: PDFSourceValue]) throws -> [UInt8] {
        let filters = dictionary["Filter"].map { $0.array ?? [$0] } ?? []
        guard filters.isEmpty || filters == [.name("FlateDecode")] else { throw PDFAppendError.unreadable }
        var data = raw
        if !filters.isEmpty {
            do { data = try Array(FlateStream.decode(Data(raw))) } catch { throw PDFAppendError.unreadable }
        }
        let parameters = dictionary["DecodeParms"].map { $0.array?.first ?? $0 }?.dictionary ?? [:]
        let predictor = parameters["Predictor"]?.integer ?? 1
        if predictor == 1 { return data }
        guard (10 ... 15).contains(predictor) else { throw PDFAppendError.unreadable }
        let columns = parameters["Columns"]?.integer ?? 1
        let colors = parameters["Colors"]?.integer ?? 1
        let bits = parameters["BitsPerComponent"]?.integer ?? 8
        guard columns > 0, colors > 0, [1, 2, 4, 8, 16].contains(bits), colors <= Int.max / bits,
              columns <= (Int.max - 7) / (colors * bits) else { throw PDFAppendError.unreadable }
        let rowSize = (columns * colors * bits + 7) / 8
        let pixelSize = (colors * bits + 7) / 8
        guard rowSize < Int.max, rowSize <= data.count,
              data.count.isMultiple(of: rowSize + 1) else { throw PDFAppendError.unreadable }
        var output: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rowSize)
        for start in stride(from: 0, to: data.count, by: rowSize + 1) {
            let filter = data[start]
            guard filter <= 4 else { throw PDFAppendError.unreadable }
            var row = Array(data[start + 1 ..< start + 1 + rowSize])
            for index in row.indices {
                let left = index >= pixelSize ? Int(row[index - pixelSize]) : 0
                let up = Int(previous[index])
                let upperLeft = index >= pixelSize ? Int(previous[index - pixelSize]) : 0
                let adjustment: Int
                switch filter {
                case 0: adjustment = 0
                case 1: adjustment = left
                case 2: adjustment = up
                case 3: adjustment = (left + up) / 2
                default: adjustment = paeth(left, up, upperLeft)
                }
                row[index] = row[index] &+ UInt8(adjustment)
            }
            output += row; previous = row
        }
        return output
    }

    private static func paeth(_ left: Int, _ up: Int, _ upperLeft: Int) -> Int {
        let prediction = left + up - upperLeft
        let a = abs(prediction - left), b = abs(prediction - up), c = abs(prediction - upperLeft)
        if a <= b, a <= c { return left }
        return b <= c ? up : upperLeft
    }
}
