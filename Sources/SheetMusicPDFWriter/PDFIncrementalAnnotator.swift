import SheetMusicFoundation

/// Adds page annotations as an incremental update (ISO 32000-1 §7.5.6), preserving every original byte.
/// The newest cross-reference section's kind is retained: a classic table or an xref stream.
public enum PDFIncrementalAnnotator {
    /// Each page's crop box, turned by its rotation, in page order and points: the displayed space used by `append`.
    public static func pageSizes(of original: Data) throws -> [PDFPageSize] {
        try PDFSourceDocument(original).pages().map(\.space.displayedSize)
    }

    /// Adds annotations by zero-based page index, after each page's existing annotations. Geometry is in the
    /// displayed space reported by `pageSizes`. Nothing drawable to add returns the original bytes unchanged.
    /// Encrypted or unreadable files and indices outside the page tree throw `PDFAppendError`.
    public static func append(_ annotations: [Int: [PDFPageAnnotation]], to original: Data) throws -> Data {
        let wanted = annotations.filter { !$0.value.isEmpty }
        guard !wanted.isEmpty else { return original }
        do {
            let document = try PDFSourceDocument(original)
            let pages = try document.pages()
            guard wanted.keys.allSatisfy(pages.indices.contains) else { throw PDFAppendError.pageOutOfRange }
            guard document.locations.keys.allSatisfy({ $0 < document.size }) else { throw PDFAppendError.unreadable }
            let writer = PDFIncrementalWriter(original: original, nextNumber: document.size)
            for index in wanted.keys.sorted() {
                let page = pages[index]
                let added = try PDFAnnotationObjects.write(wanted[index] ?? [], in: page.space, into: writer)
                    .map { PDFSourceValue.reference($0, 0) }
                guard !added.isEmpty else { continue }
                var dictionary = page.dictionary
                var existing: [PDFSourceValue] = []
                if let value = dictionary["Annots"] {
                    let resolved = try document.resolve(value)
                    if resolved != .null {
                        guard let array = resolved.array else { throw PDFAppendError.unreadable }
                        existing = array
                    }
                }
                // An indirect array may be shared by other pages: give only this page its own updated array.
                dictionary["Annots"] = .array(existing + added)
                writer.rewrite(
                    page.number, generation: page.generation, PDFSourceValue.dictionary(dictionary).serialized,
                )
            }
            guard writer.hasObjects else { return original }
            return try writer.finish(
                trailer: document.trailer, previous: document.startXRef, asStream: document.lastSectionIsStream,
            )
        } catch let error as PDFAppendError {
            throw error
        } catch {
            throw PDFAppendError.unreadable
        }
    }
}
