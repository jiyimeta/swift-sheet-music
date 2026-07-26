#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension PDFImporter {
    /// A font embedded in the PDF, as far as classification cares.
    struct EmbeddedFont {
        enum ProgramKind { case type1, trueType, cff }
        var baseFont = ""
        /// Code → glyph name, from `/Encoding /Differences`. Empty when the
        /// font uses a base encoding with no overrides.
        var differences: [UInt32: String] = [:]
        /// The embedded font program, when the producer included one.
        var program: Data?
        var programKind: ProgramKind?
    }

    /// Walk `cgPage`'s Resources → Font dictionary and collect each font's
    /// `/BaseFont`, `/Encoding /Differences`, and embedded program. Keyed by
    /// font RESOURCE NAME (the `Tf` operand), matching `extractFontCMaps`.
    static func extractEmbeddedFonts(cgPage: CGPDFPage) -> [String: EmbeddedFont] {
        guard let pageDict = cgPage.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources),
              let resources else { return [:] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts),
              let fonts else { return [:] }

        final class Sink { var map: [String: EmbeddedFont] = [:] }
        let sink = Sink()
        CGPDFDictionaryApplyFunction(fonts, { key, value, info in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            var fontDict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &fontDict),
                  let fontDict else { return }
            let name = String(cString: key)
            sink.map[name] = PDFImporter.readEmbeddedFont(fontDict)
        }, Unmanaged.passUnretained(sink).toOpaque())
        return sink.map
    }

    /// Read one font dictionary. Handles the Type0 indirection: a composite
    /// font's program lives on its DescendantFonts[0] descriptor, not its own.
    static func readEmbeddedFont(_ fontDict: CGPDFDictionaryRef) -> EmbeddedFont {
        var out = EmbeddedFont()
        var baseFont: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(fontDict, "BaseFont", &baseFont),
           let baseFont
        {
            out.baseFont = String(cString: baseFont)
        }
        out.differences = readDifferences(fontDict)

        // Descriptor: direct for simple fonts, via DescendantFonts for Type0.
        var descriptor: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(fontDict, "FontDescriptor", &descriptor) {
            var descendants: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(fontDict, "DescendantFonts", &descendants),
               let descendants, CGPDFArrayGetCount(descendants) > 0
            {
                var child: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(descendants, 0, &child), let child {
                    CGPDFDictionaryGetDictionary(child, "FontDescriptor", &descriptor)
                }
            }
        }
        guard let descriptor else { return out }
        for (key, kind) in [
            ("FontFile2", EmbeddedFont.ProgramKind.trueType),
            ("FontFile3", .cff),
            ("FontFile", .type1),
        ] {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(descriptor, key, &stream),
                  let stream else { continue }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { continue }
            out.program = data as Data
            out.programKind = kind
            break
        }
        return out
    }

    /// `/Encoding /Differences` → code → glyph name. The array alternates
    /// integer start-codes with runs of names: `[ 32 /space /exclam 48 /zero ]`.
    static func readDifferences(_ fontDict: CGPDFDictionaryRef) -> [UInt32: String] {
        var encoding: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(fontDict, "Encoding", &encoding),
              let encoding else { return [:] }
        var diffs: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(encoding, "Differences", &diffs),
              let diffs else { return [:] }
        var out: [UInt32: String] = [:]
        var code: CGPDFInteger = 0
        for i in 0 ..< CGPDFArrayGetCount(diffs) {
            var intValue: CGPDFInteger = 0
            if CGPDFArrayGetInteger(diffs, i, &intValue) {
                code = intValue
                continue
            }
            var name: UnsafePointer<Int8>?
            if CGPDFArrayGetName(diffs, i, &name), let name {
                out[UInt32(code)] = String(cString: name)
                code += 1
            }
        }
        return out
    }
}
