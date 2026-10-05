import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicPages

/// Writes a score's pages as a vector PDF, in Swift alone: each page's draw-program commands as a content stream,
/// the faces embedded whole and each only once, the text searchable. What the PDF shows is what the Windows renderer
/// draws from the same pages (`PDFPageWalker`).
public enum ScorePDFWriter {
    /// Writes `pages`, one PDF page per page at its own size, with `title` as the document's title. Lay the pages out
    /// with the font metrics installed (`ScorePages.compute`): the text is placed by the same provider. Throws when one
    /// of the bundled faces is not an OpenType file; a system face that is not one draws its text in Edwin.
    public static func write(_ pages: ScorePages, fonts: ScorePDFFonts, title: String?) throws -> Data {
        try write(pages.pages, fonts: fonts, title: title)
    }

    static func write(_ pages: [EncodablePage], fonts: ScorePDFFonts, title: String?) throws -> Data {
        let resources = try PDFResources(fonts: fonts)
        let writer = PDFObjectWriter()
        let catalog = writer.reserve()
        let pageTree = writer.reserve()
        let resourceDictionary = writer.reserve()
        var kids: [Int] = []
        let k = PDFPageWalker.pointsPerMM
        for page in pages {
            var walker = PDFPageWalker(resources: resources, pageHeightMM: page.heightMM)
            walker.walk(page.commands)
            let pageObject = writer.reserve()
            let contents = writer.reserve()
            try writer.stream(contents, dictionary: "", data: Data(walker.content.utf8), compress: true)
            let box = "[0 0 \(PDFPageWalker.number(page.widthMM * k)) \(PDFPageWalker.number(page.heightMM * k))]"
            writer.object(
                pageObject,
                "<< /Type /Page /Parent \(pageTree) 0 R /MediaBox \(box) /Resources \(resourceDictionary) 0 R "
                    + "/Contents \(contents) 0 R >>",
            )
            kids.append(pageObject)
        }
        // After the pages: only now is it known which faces they used.
        try writer.object(resourceDictionary, resources.write(into: writer))
        writer.object(
            pageTree,
            "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>",
        )
        writer.object(catalog, "<< /Type /Catalog /Pages \(pageTree) 0 R >>")
        let info = writer.reserve()
        let titleEntry = title.map { " /Title \(PDFString.text($0))" } ?? ""
        writer.object(info, "<< /Producer \(PDFString.text("swift-sheet-music"))\(titleEntry) >>")
        return writer.finish(root: catalog, info: info)
    }
}
