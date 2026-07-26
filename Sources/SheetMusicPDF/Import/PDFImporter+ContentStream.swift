import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

extension PDFImporter {
    /// Low-level content-stream walker. Enumerates each page in the
    /// document, registers `CGPDFOperatorCallback`s for the operators
    /// we care about, and collects raw glyphs / text runs / drawn path
    /// segments in PDF page coordinates.
    ///
    /// CTM, text matrix, font, and current path are tracked in a small
    /// per-page interpreter (`PageState`) which is bridged through the
    /// `CGPDFScanner`'s opaque `info` pointer via `Unmanaged`.
    struct ContentStreamWalker {
        let document: PDFDocument
        /// Threaded from `PDFImportOptions.enableShapeMatching`; forwarded to
        /// every page's `GlyphClassifier`s. Default false so existing call
        /// sites that don't pass it keep today's Tier-1-only behavior.
        var enableShapeMatching = false
        /// Threaded from `PDFImportOptions.disableSMuFLCodepointTier`;
        /// forwarded to every page's `GlyphClassifier`s. TESTING ONLY —
        /// default false.
        var disableSMuFLCodepointTier = false
        /// Threaded from `PDFImportOptions.anchorMusicGlyphsToPUARange`;
        /// forwarded to every page's `PDFPageState`. TESTING ONLY — default
        /// false.
        var anchorMusicToPUARange = false
        /// Threaded from `PDFImportOptions.bypassMusicFontGateForTesting`;
        /// forwarded to every page's `GlyphClassifier`s. TESTING ONLY —
        /// default false.
        var bypassMusicFontGate = false

        func walk() throws -> WalkedContent {
            var glyphs: [ClassifiedGlyph] = []
            var texts: [TextGlyph] = []
            var paths: [PathSegment] = []
            var curves: [CurveArc] = []
            for pageIndex in 0 ..< document.pageCount {
                guard let page = document.page(at: pageIndex),
                      let cgPage = page.pageRef
                else { continue }
                let state = PDFPageState(pageIndex: pageIndex)
                state.anchorMusicToPUARange = anchorMusicToPUARange
                walkPage(cgPage: cgPage, state: state)
                glyphs.append(contentsOf: state.glyphs)
                texts.append(contentsOf: state.texts)
                paths.append(contentsOf: state.paths)
                curves.append(contentsOf: state.curveArcs)
            }
            return WalkedContent(glyphs: glyphs, texts: texts, paths: paths, curves: curves)
        }

        private func walkPage(cgPage: CGPDFPage, state: PDFPageState) {
            // The page/font dict is reachable ONLY here (the @convention(c)
            // callbacks are capture-free). Extract every font's /ToUnicode
            // CMap now and stash it on PageState keyed by resource name so
            // op_Tf can select the active CMap.
            state.fontCMaps = PDFImporter.extractFontCMaps(cgPage: cgPage)
            let embedded = PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
            state.classifiers = embedded.mapValues {
                GlyphClassifier(
                    font: $0, enableShapeMatching: enableShapeMatching,
                    disableSMuFLTier: disableSMuFLCodepointTier,
                    bypassMusicFontGate: bypassMusicFontGate,
                )
            }
            guard let table = CGPDFOperatorTableCreate() else { return }
            defer { CGPDFOperatorTableRelease(table) }
            ContentStreamOperators.register(on: table)
            let stream = CGPDFContentStreamCreateWithPage(cgPage)
            let info = Unmanaged.passUnretained(state).toOpaque()
            let scanner = CGPDFScannerCreate(stream, table, info)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }
    }

    /// Walk `cgPage`'s Resources → Font dictionary and build a
    /// `[resourceName: ToUnicodeCMap]` registry. The /ToUnicode stream
    /// lives on the top-level Type0 font dict; `CGPDFStreamCopyData`
    /// auto-inflates FlateDecode and yields plaintext CMap bytes.
    static func extractFontCMaps(cgPage: CGPDFPage) -> [String: ToUnicodeCMap] {
        guard let pageDict = cgPage.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources),
              let resources
        else { return [:] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts),
              let fonts
        else { return [:] }

        // CGPDFDictionaryApplyFunction's @convention(c) closure can't
        // capture; route entries through a heap box via the opaque info ptr.
        final class Sink { var map: [String: ToUnicodeCMap] = [:] }
        let sink = Sink()
        let info = Unmanaged.passUnretained(sink).toOpaque()
        CGPDFDictionaryApplyFunction(fonts, { key, value, info in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let resName = String(cString: key)
            var fontDict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &fontDict),
                  let fontDict
            else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(fontDict, "ToUnicode", &stream),
                  let stream
            else { return }
            var format: CGPDFDataFormat = .raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { return }
            let cmap = ToUnicodeCMap.parse(data: data as Data)
            if !cmap.isEmpty { sink.map[resName] = cmap }
        }, info)
        return sink.map
    }
}
