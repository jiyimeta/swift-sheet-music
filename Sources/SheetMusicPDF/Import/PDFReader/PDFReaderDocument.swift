#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// A Foundation-only reader for the bounded family of PDFs that MuseScore
/// 3.x / 4.x exports: `%PDF-1.4`, classic `xref` table + `trailer` dict,
/// `/FlateDecode` streams only, no xref/object streams, no encryption.
///
/// Objects are resolved by a brute-force scan for every `N G obj … endobj`
/// across the whole file (the xref offsets are ignored). The `startxref` /
/// `trailer` machinery is consulted only to find `/Root` and `/Info`.
struct PDFReaderDocument {
    private let objects: [Int: PDFObject]
    private let trailer: [String: PDFObject]
    private let pages: [PDFPageNode]

    /// Parse the whole file. Returns `nil` if no objects or no pages are found.
    init?(data: Data) {
        let bytes = [UInt8](data)
        let objects = Self.buildObjectIndex(bytes: bytes)
        guard !objects.isEmpty else {
            return nil
        }
        let trailer = Self.findTrailer(bytes: bytes, objects: objects)
        let pages = Self.collectPages(objects: objects, trailer: trailer)
        guard !pages.isEmpty else {
            return nil
        }
        self.objects = objects
        self.trailer = trailer
        self.pages = pages
    }

    var pageCount: Int {
        pages.count
    }

    /// The page's MediaBox size (inherited from the page tree when absent on
    /// the page itself). `nil` if unavailable — the caller supplies a default.
    func mediaBox(page: Int) -> CGSize? {
        guard pages.indices.contains(page) else {
            return nil
        }
        guard case let .array(arr)? = resolve(pages[page].mediaBox), arr.count == 4 else {
            return nil
        }
        let nums = arr.compactMap { resolve($0)?.doubleValue }
        guard nums.count == 4 else {
            return nil
        }
        return CGSize(
            width: CGFloat(abs(nums[2] - nums[0])),
            height: CGFloat(abs(nums[3] - nums[1])),
        )
    }

    /// The page's `/Contents`, concatenated (an array of streams is joined)
    /// and inflated. Empty `Data` if the page has no content.
    func contentBytes(page: Int) -> Data {
        guard pages.indices.contains(page) else {
            return Data()
        }
        guard let contents = resolve(pages[page].dict["Contents"]) else {
            return Data()
        }
        var streamObjects = [PDFObject]()
        if case let .array(arr) = contents {
            for element in arr {
                if let resolved = resolve(element) {
                    streamObjects.append(resolved)
                }
            }
        } else {
            streamObjects.append(contents)
        }
        var out = Data()
        for object in streamObjects {
            guard case let .stream(dict, raw) = object else {
                continue
            }
            out.append(decodeStream(dict: dict, raw: raw))
            out.append(PDFBytes.lineFeed) // keep tokens from merging across streams
        }
        return out
    }

    /// What the show path needs from a page's `/Resources` → `/Font` dict:
    /// every font's inflated `/ToUnicode` CMap bytes, keyed by the Font dict
    /// KEY (e.g. `"F10"`), and the keys whose `/Subtype` is `/Type0`.
    ///
    /// The subtype comes back with the CMaps because it — not whether a font
    /// has a CMap — decides how many bytes one shown code is; see
    /// `PDFPageState.type0FontNames`.
    struct PageFonts {
        var toUnicode: [String: Data] = [:]
        var type0Names: Set<String> = []
    }

    func pageFonts(page: Int) -> PageFonts {
        guard pages.indices.contains(page) else {
            return PageFonts()
        }
        guard case let .dictionary(resources)? = resolve(pages[page].resources) else {
            return PageFonts()
        }
        guard case let .dictionary(fonts)? = resolve(resources["Font"]) else {
            return PageFonts()
        }
        var result = PageFonts()
        for (name, fontRef) in fonts {
            guard case let .dictionary(fontDict)? = resolve(fontRef) else {
                continue
            }
            if case let .name(subtype)? = resolve(fontDict["Subtype"]), subtype == "Type0" {
                result.type0Names.insert(name)
            }
            guard case let .stream(dict, raw)? = resolve(fontDict["ToUnicode"]) else {
                continue
            }
            result.toUnicode[name] = decodeStream(dict: dict, raw: raw)
        }
        return result
    }

    /// The `/Info` dictionary flattened to `[String: Any]` with `String`
    /// values (best-effort; used for a title fallback). `nil` if absent/empty.
    var documentAttributes: [String: Any]? {
        guard case let .dictionary(info)? = resolve(trailer["Info"]) else {
            return nil
        }
        var out = [String: Any]()
        for (key, value) in info {
            if let text = decodePDFText(resolve(value)) {
                out[key] = text
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Resolution

    private func resolve(_ obj: PDFObject?) -> PDFObject? {
        Self.resolve(obj, in: objects)
    }

    /// Follow indirect references through the object index (bounded to guard
    /// against reference cycles).
    static func resolve(_ obj: PDFObject?, in objects: [Int: PDFObject]) -> PDFObject? {
        var current = obj
        var hops = 0
        while case let .reference(num, _)? = current, hops < 32 {
            current = objects[num]
            hops += 1
        }
        return current
    }

    // MARK: - Stream & string decoding

    private func decodeStream(dict: [String: PDFObject], raw: [UInt8]) -> Data {
        var filters = [String]()
        switch resolve(dict["Filter"]) {
        case let .name(n):
            filters = [n]
        case let .array(arr):
            filters = arr.compactMap { resolve($0)?.nameValue }
        default:
            filters = []
        }
        if filters.isEmpty {
            return Data(raw)
        }
        var data = Data(raw)
        for filter in filters {
            if filter == "FlateDecode" || filter == "Fl" {
                guard let inflated = PDFFlate.inflate(data) else {
                    return Data()
                }
                data = inflated
            } else {
                return Data() // unsupported filter — skip this stream, don't crash
            }
        }
        return data
    }

    /// Decode a PDF text string: UTF-16BE when it starts with the `FE FF` BOM,
    /// otherwise UTF-8 with a Latin-1 fallback.
    private func decodePDFText(_ obj: PDFObject?) -> String? {
        switch obj {
        case let .string(bytes):
            if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
                var units = [UInt16]()
                var i = 2
                while i + 1 < bytes.count {
                    units.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
                    i += 2
                }
                return String(decoding: units, as: UTF16.self)
            }
            if let utf8 = String(bytes: bytes, encoding: .utf8) {
                return utf8
            }
            return String(bytes: bytes, encoding: .isoLatin1)
        case let .name(n):
            return n
        default:
            return nil
        }
    }
}
