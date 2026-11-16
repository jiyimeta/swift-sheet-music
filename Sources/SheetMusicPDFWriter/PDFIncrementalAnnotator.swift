import SheetMusicFoundation
import SheetMusicPDFSyntax

/// Adds page annotations as an incremental update (ISO 32000-1 §7.5.6), preserving every original byte.
/// The newest cross-reference section's kind is retained: a classic table or an xref stream.
public enum PDFIncrementalAnnotator {
    /// Each page's crop box, turned by its rotation, in page order and points: the displayed space used by `append`.
    /// An encrypted file is read with this platform's own primitives (`PDFPlatformCrypto.primitives`).
    public static func pageSizes(of original: Data) throws -> [PDFPageSize] {
        try pageSizes(of: original, crypto: PDFPlatformCrypto.primitives)
    }

    /// `pageSizes(of:)` with the primitives to open an encrypted file with — Android's, from its host — or nil to
    /// refuse one (`PDFAppendError.encrypted`).
    public static func pageSizes(of original: Data, crypto: (any PDFCryptoPrimitives)?) throws -> [PDFPageSize] {
        try PDFSourceDocument(original, encryption: encryption(crypto)).pages().map(\.space.displayedSize)
    }

    /// Each page's media box, displayed crop box and turn, in page order — what `pageSizes` is derived from. An
    /// encrypted file is read with this platform's own primitives.
    public static func pageBoxes(of original: Data) throws -> [PDFPageBoxes] {
        try pageBoxes(of: original, crypto: PDFPlatformCrypto.primitives)
    }

    /// The encryption dictionary's permissions (`/P`), which are stated in the clear, or nil for a file that is not
    /// encrypted. Reads no key: a file that needs a user password still answers.
    public static func permissions(of original: Data) throws -> PDFPermissions? {
        let document = try PDFSourceDocument(original, encryption: .dictionaryOnly)
        guard let encrypt = document.encryptDictionary else { return nil }
        guard let value = encrypt["P"]?.integerValue else { throw PDFAppendError.unreadable }
        return PDFPermissions(rawValue: Int32(truncatingIfNeeded: value))
    }

    /// `pageBoxes(of:)` with the primitives to open an encrypted file with, or nil to refuse one.
    public static func pageBoxes(of original: Data, crypto: (any PDFCryptoPrimitives)?) throws -> [PDFPageBoxes] {
        try PDFSourceDocument(original, encryption: encryption(crypto)).pages().map { page in
            let space = page.space
            return PDFPageBoxes(
                mediaBox: PDFUserBox(
                    left: page.mediaBox[0], bottom: page.mediaBox[1], right: page.mediaBox[2], top: page.mediaBox[3],
                ),
                cropBox: PDFUserBox(left: space.left, bottom: space.bottom, right: space.right, top: space.top),
                rotation: space.rotation,
                userUnit: space.userUnit,
            )
        }
    }

    /// Adds annotations by zero-based page index, after each page's existing annotations. Geometry is in the
    /// displayed space reported by `pageSizes`. Nothing drawable to add returns the original bytes unchanged.
    /// Encrypted or unreadable files and indices outside the page tree throw `PDFAppendError`.
    ///
    /// An encrypted original is refused here even where the platform has primitives: writing into one is the caller's
    /// decision, since its owner's `/P` may forbid annotations (`permissions(of:)`). `append(_:to:crypto:)` writes it.
    public static func append(_ annotations: [Int: [PDFPageAnnotation]], to original: Data) throws -> Data {
        try append(annotations, to: original, crypto: nil)
    }

    /// `append(_:to:)` that also writes into an encrypted original whose user password is empty, with `crypto` —
    /// `PDFPlatformCrypto.primitives`, or Android's from its host. The original bytes stay as they are, the update
    /// carries the trailer's `/Encrypt` and `/ID`, and what it adds is encrypted under the original's key and methods,
    /// so the file opens where it opened before, with the restrictions it had. This does not read `/P`: a caller that
    /// honors the owner's restrictions asks `permissions(of:)` first. Nil `crypto` refuses an encrypted original
    /// (`.encrypted`); a file that needs a user password throws `.passwordRequired`.
    public static func append(
        _ annotations: [Int: [PDFPageAnnotation]], to original: Data, crypto: (any PDFCryptoPrimitives)?,
    ) throws -> Data {
        let wanted = annotations.filter { !$0.value.isEmpty }
        guard !wanted.isEmpty else { return original }
        do {
            let document = try PDFSourceDocument(original, encryption: encryption(crypto))
            let pages = try document.pages()
            guard wanted.keys.allSatisfy(pages.indices.contains) else { throw PDFAppendError.pageOutOfRange }
            guard document.locations.keys.allSatisfy({ $0 < document.size }) else { throw PDFAppendError.unreadable }
            let writer = PDFIncrementalWriter(
                original: original, nextNumber: document.size, security: document.security,
            )
            for index in wanted.keys.sorted() {
                let page = pages[index]
                let added = try PDFAnnotationObjects.write(wanted[index] ?? [], in: page.space, into: writer)
                    .map { PDFObject.reference($0, 0) }
                guard !added.isEmpty else { continue }
                var dictionary = page.dictionary
                var existing: [PDFObject] = []
                if let value = dictionary["Annots"] {
                    let resolved = try document.resolve(value)
                    if resolved != .null {
                        guard let array = resolved.arrayValue else { throw PDFAppendError.unreadable }
                        existing = array
                    }
                }
                // An indirect array may be shared by other pages: give only this page its own updated array.
                dictionary["Annots"] = .array(existing + added)
                let rewritten = try encrypted(
                    .dictionary(dictionary), number: page.number, generation: page.generation,
                    security: document.security,
                )
                writer.rewrite(page.number, generation: page.generation, rewritten.serialized)
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

    private static func encryption(_ crypto: (any PDFCryptoPrimitives)?) -> PDFSourceDocument.Encryption {
        crypto.map { .decrypt($0) } ?? .refuse
    }

    /// A rewritten object's strings, encrypted under its own number and generation. The document decrypted every
    /// string it read — a page from an object stream held them in the clear to begin with — so each is plain here and
    /// all of them are encrypted again; without `security` the object is returned as it is.
    static func encrypted(
        _ object: PDFObject, number: Int, generation: Int, security: PDFStandardSecurity?,
    ) throws -> PDFObject {
        guard let security else { return object }
        return try PDFSourceDocument.mapStrings(object) {
            try security.encrypt($0, number: number, generation: generation, method: security.stringMethod)
        }
    }
}

/// An encrypted file's `/P` (ISO 32000-2 Table 22): what its owner allows a reader that opened it without the owner
/// password. Bits are numbered from 1, as the standard numbers them.
public struct PDFPermissions: Equatable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Bit 6: add or modify annotations (and fill in form fields). Off, an export that adds ink to the original is
    /// refused rather than written.
    public var allowsAnnotations: Bool {
        allows(bit: 6)
    }

    /// Bit 3: print.
    public var allowsPrinting: Bool {
        allows(bit: 3)
    }

    public func allows(bit: Int) -> Bool {
        (1 ... 32).contains(bit) && UInt32(bitPattern: rawValue) & (UInt32(1) << UInt32(bit - 1)) != 0
    }
}
