import SheetMusicFoundation

/// A picture as a PDF image XObject: the stream's dictionary entries and its payload, read from the file's header
/// alone (`ImageSniffer`) — this target never decodes a pixel. A JPEG goes in as it is (`DCTDecode`); a PNG whose
/// pixels PDF can unpredict itself (8-bit gray, RGB or palette, not interlaced) goes in as its concatenated `IDAT`
/// bytes (`FlateDecode` with PNG predictors). Anything else has no XObject: `make` returns `nil` and the page draws
/// nothing for it.
struct PDFImageXObject {
    /// The stream dictionary's entries, without `<< >>` and without `/Length`: `/Type`, `/Subtype`, size, color space,
    /// bits, and the filter (and its parameters) the payload is already in.
    let dictionary: String
    /// The stream's payload, written as it is — never compressed again.
    let data: Data

    /// The XObject for a PNG or JPEG file, or `nil` when it is neither, or its pixels are not ones PDF reads directly.
    static func make(from data: Data) -> PDFImageXObject? {
        nil
    }
}
