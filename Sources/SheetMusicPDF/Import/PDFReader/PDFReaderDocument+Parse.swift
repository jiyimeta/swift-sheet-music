#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// A collected page: its own dictionary plus the MediaBox / Resources
/// resolved through page-tree inheritance.
struct PDFPageNode {
    let dict: [String: PDFObject]
    let mediaBox: PDFObject?
    let resources: PDFObject?
}

extension PDFReaderDocument {
    // MARK: - Brute-force object index

    /// Scan the whole file for every `N G obj … endobj` and build an
    /// `objNum -> PDFObject` index (generation ignored; last definition wins).
    static func buildObjectIndex(bytes: [UInt8]) -> [Int: PDFObject] {
        var objects = [Int: PDFObject]()
        var pendingStreams = [PendingStream]()
        let objKeyword: [UInt8] = [0x6F, 0x62, 0x6A] // "obj"
        let count = bytes.count
        var i = 0
        while i + 2 < count {
            guard bytes[i] == objKeyword[0], bytes[i + 1] == objKeyword[1], bytes[i + 2] == objKeyword[2] else {
                i += 1
                continue
            }
            let after = i + 3
            let afterOK = after >= count
                || PDFBytes.isWhitespace(bytes[after]) || PDFBytes.isDelimiter(bytes[after])
            let beforeOK = i > 0 && PDFBytes.isWhitespace(bytes[i - 1])
            guard afterOK, beforeOK, let header = parseObjectHeader(bytes: bytes, beforeObj: i - 1),
                  let body = parseObjectBody(bytes: bytes, at: after)
            else {
                i += 1
                continue
            }
            if let stream = body.stream, case let .dictionary(dict) = body.object {
                pendingStreams.append(
                    PendingStream(
                        objNum: header.objNum, dict: dict,
                        rawStart: stream.rawStart, contentEnd: stream.contentEnd,
                    ),
                )
            } else {
                objects[header.objNum] = body.object
            }
            i = max(after, body.endPos)
        }
        // Second pass: resolve (possibly indirect) /Length now the index is complete.
        for pending in pendingStreams {
            let raw = resolveStreamRaw(bytes: bytes, pending: pending, objects: objects)
            objects[pending.objNum] = .stream(dict: pending.dict, raw: raw)
        }
        return objects
    }

    private struct PendingStream {
        let objNum: Int
        let dict: [String: PDFObject]
        let rawStart: Int
        let contentEnd: Int
    }

    /// Read the `N G` header immediately preceding an `obj` keyword by
    /// backtracking over whitespace and two integer runs.
    private static func parseObjectHeader(bytes: [UInt8], beforeObj: Int) -> (objNum: Int, gen: Int)? {
        var p = beforeObj
        while p >= 0, PDFBytes.isWhitespace(bytes[p]) {
            p -= 1
        }
        let genEnd = p + 1
        while p >= 0, PDFBytes.isDigit(bytes[p]) {
            p -= 1
        }
        let genStart = p + 1
        guard genStart < genEnd, p >= 0, PDFBytes.isWhitespace(bytes[p]) else {
            return nil
        }
        while p >= 0, PDFBytes.isWhitespace(bytes[p]) {
            p -= 1
        }
        let numEnd = p + 1
        while p >= 0, PDFBytes.isDigit(bytes[p]) {
            p -= 1
        }
        let numStart = p + 1
        guard numStart < numEnd,
              let gen = Int(asciiString(bytes, genStart, genEnd)),
              let num = Int(asciiString(bytes, numStart, numEnd))
        else {
            return nil
        }
        return (num, gen)
    }

    /// Parse an object body at `start`. If the value is a dictionary followed
    /// by a `stream`, report the raw payload span (still-encoded).
    private static func parseObjectBody(
        bytes: [UInt8], at start: Int,
    ) -> (object: PDFObject, stream: (rawStart: Int, contentEnd: Int)?, endPos: Int)? {
        var parser = PDFObjectParser(bytes, at: start)
        guard let value = parser.parseObject() else {
            return nil
        }
        guard case .dictionary = value else {
            return (value, nil, parser.pos)
        }
        var p = parser.pos
        while p < bytes.count, PDFBytes.isWhitespace(bytes[p]) {
            p += 1
        }
        let streamKeyword: [UInt8] = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D] // "stream"
        guard PDFBytes.matches(streamKeyword, bytes, p) else {
            return (value, nil, parser.pos)
        }
        p += streamKeyword.count
        // Exactly one EOL marker follows `stream` (CRLF or LF, never bare CR).
        if p < bytes.count, bytes[p] == PDFBytes.carriageReturn {
            p += 1
            if p < bytes.count, bytes[p] == PDFBytes.lineFeed { p += 1 }
        } else if p < bytes.count, bytes[p] == PDFBytes.lineFeed {
            p += 1
        }
        let rawStart = p
        let endKeyword: [UInt8] = [0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D] // "endstream"
        let contentEnd = PDFBytes.firstIndex(of: endKeyword, in: bytes, from: rawStart) ?? bytes.count
        let endPos = min(bytes.count, contentEnd + endKeyword.count)
        return (value, (rawStart, contentEnd), endPos)
    }

    /// Prefer the resolved `/Length` slice; fall back to the scanned
    /// delimiters (trimming one trailing EOL before `endstream`).
    private static func resolveStreamRaw(
        bytes: [UInt8], pending: PendingStream, objects: [Int: PDFObject],
    ) -> [UInt8] {
        let rawStart = pending.rawStart
        let contentEnd = pending.contentEnd
        if let length = resolve(pending.dict["Length"], in: objects)?.intValue,
           length >= 0, rawStart + length <= contentEnd
        {
            return Array(bytes[rawStart ..< (rawStart + length)])
        }
        var end = contentEnd
        if end > rawStart, bytes[end - 1] == PDFBytes.lineFeed {
            end -= 1
            if end > rawStart, bytes[end - 1] == PDFBytes.carriageReturn { end -= 1 }
        } else if end > rawStart, bytes[end - 1] == PDFBytes.carriageReturn {
            end -= 1
        }
        guard rawStart <= end else {
            return []
        }
        return Array(bytes[rawStart ..< end])
    }

    private static func asciiString(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        PDFBytes.string(bytes[start ..< end])
    }

    // MARK: - Trailer

    /// The last `trailer` dictionary that carries `/Root`; if none does, the
    /// last trailer dictionary; failing that, one synthesized from a Catalog.
    static func findTrailer(bytes: [UInt8], objects: [Int: PDFObject]) -> [String: PDFObject] {
        let trailerKeyword: [UInt8] = [0x74, 0x72, 0x61, 0x69, 0x6C, 0x65, 0x72] // "trailer"
        var positions = [Int]()
        var from = 0
        while let idx = PDFBytes.firstIndex(of: trailerKeyword, in: bytes, from: from) {
            positions.append(idx)
            from = idx + trailerKeyword.count
        }
        var lastDict: [String: PDFObject]?
        for idx in positions.reversed() {
            var parser = PDFObjectParser(bytes, at: idx + trailerKeyword.count)
            guard case let .dictionary(dict)? = parser.parseObject() else {
                continue
            }
            if lastDict == nil {
                lastDict = dict
            }
            if dict["Root"] != nil {
                return dict
            }
        }
        if let lastDict {
            return lastDict
        }
        if let catalog = findCatalog(objects: objects) {
            return ["Root": .reference(catalog, 0)]
        }
        return [:]
    }

    private static func findCatalog(objects: [Int: PDFObject]) -> Int? {
        for (num, obj) in objects {
            if case let .dictionary(dict) = obj, dict["Type"]?.nameValue == "Catalog" {
                return num
            }
        }
        return nil
    }

    // MARK: - Page tree

    static func collectPages(objects: [Int: PDFObject], trailer: [String: PDFObject]) -> [PDFPageNode] {
        var root: [String: PDFObject]?
        if case let .dictionary(dict)? = resolve(trailer["Root"], in: objects) {
            root = dict
        } else if let catalog = findCatalog(objects: objects), case let .dictionary(dict)? = objects[catalog] {
            root = dict
        }
        guard let root, case let .dictionary(pagesRoot)? = resolve(root["Pages"], in: objects) else {
            return []
        }
        var pages = [PDFPageNode]()
        var visited = Set<Int>()
        walkNode(
            pagesRoot, mediaBox: nil, resources: nil,
            objects: objects, pages: &pages, visited: &visited,
        )
        return pages
    }

    /// Recursively walk `/Kids`, inheriting `/MediaBox` and `/Resources`.
    /// A node without `/Kids` is a leaf page.
    private static func walkNode(
        _ node: [String: PDFObject],
        mediaBox: PDFObject?, resources: PDFObject?,
        objects: [Int: PDFObject],
        pages: inout [PDFPageNode], visited: inout Set<Int>,
    ) {
        let inheritedMediaBox = node["MediaBox"] ?? mediaBox
        let inheritedResources = node["Resources"] ?? resources
        guard case let .array(kids)? = resolve(node["Kids"], in: objects) else {
            pages.append(
                PDFPageNode(dict: node, mediaBox: inheritedMediaBox, resources: inheritedResources),
            )
            return
        }
        for kid in kids {
            if case let .reference(num, _) = kid {
                if visited.contains(num) {
                    continue
                }
                visited.insert(num)
            }
            guard case let .dictionary(child)? = resolve(kid, in: objects) else {
                continue
            }
            walkNode(
                child, mediaBox: inheritedMediaBox, resources: inheritedResources,
                objects: objects, pages: &pages, visited: &visited,
            )
        }
    }
}
