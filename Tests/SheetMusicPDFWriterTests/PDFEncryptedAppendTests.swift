import Foundation
#if canImport(PDFKit)
    import PDFKit
#endif
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

/// Writing ink into an encrypted original whose user password is empty, as an incremental update: the original bytes
/// stay, the update carries `/Encrypt` and `/ID`, and what it adds is encrypted under the original's key. The files are
/// the read tests' (`Fixtures/Encrypted/README.md`); the same ink appended to their unencrypted original is the check
/// that the encrypted appearance decrypts to the very bytes a clear file would hold, and PDFKit is the reader that did
/// not write them.
@Suite(.enabled(if: PDFPlatformCrypto.primitives != nil))
struct PDFEncryptedAppendTests {
    static let encrypted = ["rc4-40", "rc4-128", "aes128-allowed"]
    static let ink = PDFPageAnnotationTests.ink(x: 20, y: 30)

    private let crypto: any PDFCryptoPrimitives

    init() throws {
        crypto = try #require(PDFPlatformCrypto.primitives)
    }

    private func append(to name: String, crypto: (any PDFCryptoPrimitives)? = nil) throws -> Data {
        try PDFIncrementalAnnotator.append(
            [0: [Self.ink]], to: PDFEncryptedReadTests.fixture(name), crypto: crypto ?? self.crypto,
        )
    }

    /// The first page's annotation count and its last annotation's dictionary and appearance payload, as `encryption`
    /// reads them (`.dictionaryOnly` leaves every string and stream as stored).
    private func lastAnnotation(
        _ data: Data, encryption: PDFSourceDocument.Encryption,
    ) throws -> (count: Int, annotation: [String: PDFObject], appearance: [UInt8]) {
        let document = try PDFSourceDocument(data, encryption: encryption)
        let page = try #require(try document.pages().first)
        let annots = try #require(page.dictionary["Annots"])
        let list = try #require(try document.resolve(annots).arrayValue)
        let last = try #require(list.last)
        let annotation = try #require(try document.resolve(last).dictionaryValue)
        let appearances = try #require(annotation["AP"]?.dictionaryValue)
        let normal = try #require(appearances["N"])
        guard case let .stream(_, raw) = try document.resolve(normal) else {
            Issue.record("the appearance is not a stream")
            return (list.count, annotation, [])
        }
        return (list.count, annotation, raw)
    }

    private func annotationCount(_ data: Data, encryption: PDFSourceDocument.Encryption) throws -> Int {
        let document = try PDFSourceDocument(data, encryption: encryption)
        let page = try #require(try document.pages().first)
        guard let annots = page.dictionary["Annots"] else { return 0 }
        return try document.resolve(annots).arrayValue?.count ?? 0
    }

    @Test(arguments: encrypted)
    func `the ink decrypts to the bytes the clear original gets, after the original's own bytes`(name: String) throws {
        let original = try PDFEncryptedReadTests.fixture(name)
        let output = try append(to: name)
        #expect(output.starts(with: original))
        let clear = try lastAnnotation(
            PDFIncrementalAnnotator.append([0: [Self.ink]], to: PDFEncryptedReadTests.fixture("plain")),
            encryption: .refuse,
        )
        let read = try lastAnnotation(output, encryption: .decrypt(crypto))
        #expect(try read.count == annotationCount(original, encryption: .decrypt(crypto)) + 1)
        // The appearance's object number differs (the files' sizes do); everything else is the same dictionary.
        #expect(read.annotation.filter { $0.key != "AP" } == clear.annotation.filter { $0.key != "AP" })
        #expect(read.appearance == clear.appearance)
        let stored = try lastAnnotation(output, encryption: .dictionaryOnly)
        #expect(stored.appearance != clear.appearance)
    }

    @Test(arguments: encrypted)
    func `the update carries the original's encryption and identity`(name: String) throws {
        let originalDocument = try PDFSourceDocument(PDFEncryptedReadTests.fixture(name), encryption: .dictionaryOnly)
        let output = try PDFSourceDocument(append(to: name), encryption: .dictionaryOnly)
        #expect(output.trailer["Encrypt"] == originalDocument.trailer["Encrypt"])
        #expect(output.trailer["ID"] == originalDocument.trailer["ID"])
        #expect(output.encryptDictionary == originalDocument.encryptDictionary)
        #expect(throws: PDFAppendError.encrypted) { try PDFSourceDocument(append(to: name)) }
    }

    @Test func `a file that needs a user password is refused as such`() {
        #expect(throws: PDFAppendError.passwordRequired) { try append(to: "aes128-user-password") }
    }

    @Test func `without primitives an encrypted original is refused`() {
        #expect(throws: PDFAppendError.encrypted) {
            try PDFIncrementalAnnotator.append(
                [0: [Self.ink]], to: PDFEncryptedReadTests.fixture("aes128-allowed"), crypto: nil,
            )
        }
    }

    /// AES takes its iv from the primitives (the spec's D7), so fixed random bytes give the same file twice; the
    /// platform's own give a different one each time.
    @Test func `the same random bytes write the same file`() throws {
        let fixed = FixedRandomCrypto(base: crypto)
        let repeated = try (append(to: "aes128-allowed", crypto: fixed), append(to: "aes128-allowed", crypto: fixed))
        #expect(repeated.0 == repeated.1)
        let random = try (append(to: "aes128-allowed"), append(to: "aes128-allowed"))
        #expect(random.0 != random.1)
    }

    @Test(arguments: ["rc4-128", "aes128-allowed"])
    func `a rewritten page's strings are encrypted under its own number`(name: String) throws {
        let security = try #require(
            try PDFSourceDocument(PDFEncryptedReadTests.fixture(name), encryption: .decrypt(crypto)).security,
        )
        let text = Array("a page's own string".utf8)
        let page = PDFObject.dictionary(["Type": .name("Page"), "PieceInfo": .array([.string(text)])])
        let written = try PDFIncrementalAnnotator.encrypted(page, number: 9, generation: 0, security: security)
        let stored = try #require(written.dictionaryValue?["PieceInfo"]?.arrayValue?.first?.stringBytes)
        #expect(stored != text)
        #expect(try security.decrypt(stored, number: 9, generation: 0, method: security.stringMethod) == text)
        #expect(try PDFIncrementalAnnotator.encrypted(page, number: 9, generation: 0, security: nil) == page)
    }

    /// pypdf's file whose page holds a string of its own (`/PieceInfo`): the page is decrypted on reading and
    /// rewritten with the ink, so unless its string is encrypted again under the page's number a reader decrypts it
    /// into noise.
    @Test func `a rewritten page's own string still reads after the ink is added`() throws {
        let original = try PDFSourceDocument(
            PDFEncryptedReadTests.fixture("rc4-128-page-string"), encryption: .decrypt(crypto),
        )
        #expect(try Self.pageString(#require(try original.pages().first).dictionary) == Self.pageText)
        let data = try append(to: "rc4-128-page-string")
        let page = try #require(try PDFSourceDocument(data, encryption: .decrypt(crypto)).pages().first)
        #expect(Self.pageString(page.dictionary) == Self.pageText)
        #expect(try annotationCount(data, encryption: .decrypt(crypto)) == 1)
    }

    static let pageText = Array("a page's own string".utf8)

    static func pageString(_ page: [String: PDFObject]) -> [UInt8]? {
        page["PieceInfo"]?.dictionaryValue?["folino"]?.dictionaryValue?["Private"]?.stringBytes
    }

    /// The writer encrypts streams only: an annotation dictionary holding a string would be written in the clear
    /// inside an encrypted file. None does.
    @Test func `an added annotation holds no strings`() throws {
        let highlight = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 50, y: 100, width: 200, height: 40), color: PDFPageAnnotationTests.red,
        ))
        let output = try PDFIncrementalAnnotator.append(
            [0: [Self.ink, highlight]], to: PDFEncryptedReadTests.fixture("plain"),
        )
        let document = try PDFSourceDocument(output)
        let page = try #require(try document.pages().first)
        let annots = try #require(page.dictionary["Annots"])
        for reference in try #require(try document.resolve(annots).arrayValue).suffix(2) {
            #expect(try !Self.holdsString(document.resolve(reference)))
        }
    }

    static func holdsString(_ value: PDFObject) -> Bool {
        switch value {
        case .string: true
        case let .array(items): items.contains(where: holdsString)
        case let .dictionary(entries): entries.values.contains(where: holdsString)
        case let .stream(dictionary, _): dictionary.values.contains(where: holdsString)
        default: false
        }
    }

    #if canImport(PDFKit)
        /// PDFKit, which did not write it, opens the file without a password, still encrypted, with the ink added and
        /// the owner's restrictions as they were. PDFKit's annotation API does not show whether the appearance
        /// decrypted — with the stream left in the clear this still passes — so the ssm read above is that check.
        @Test(arguments: encrypted)
        func `PDFKit opens the result without a password, with the ink and the original's restrictions`(
            name: String,
        ) throws {
            let original = try #require(PDFDocument(data: PDFEncryptedReadTests.fixture(name)))
            let output = try #require(PDFDocument(data: append(to: name)))
            #expect(output.isEncrypted)
            #expect(!output.isLocked)
            let before = try #require(original.page(at: 0)).annotations
            let after = try #require(output.page(at: 0)).annotations
            #expect(after.count == before.count + 1)
            #expect(after.last?.type == "Ink")
            #expect(output.allowsCommenting == original.allowsCommenting)
            #expect(output.allowsPrinting == original.allowsPrinting)
            #expect(output.allowsCopying == original.allowsCopying)
            #expect(output.allowsContentAccessibility == original.allowsContentAccessibility)
        }

        /// CoreGraphics reads the rewritten page's own string as pypdf wrote it.
        @Test func `the rewritten page's own string reads the same in CoreGraphics`() throws {
            let provider = try #require(CGDataProvider(data: append(to: "rc4-128-page-string") as CFData))
            let document = try #require(CGPDFDocument(provider))
            #expect(document.isEncrypted)
            #expect(document.isUnlocked)
            let page = try #require(document.page(at: 1)?.dictionary)
            var pieceInfo: CGPDFDictionaryRef?
            var folino: CGPDFDictionaryRef?
            var string: CGPDFStringRef?
            #expect(CGPDFDictionaryGetDictionary(page, "PieceInfo", &pieceInfo))
            #expect(try CGPDFDictionaryGetDictionary(#require(pieceInfo), "folino", &folino))
            #expect(try CGPDFDictionaryGetString(#require(folino), "Private", &string))
            let text = try #require(string.flatMap(CGPDFStringCopyTextString)) as String
            #expect(text == "a page's own string")
        }
    #endif
}

/// The platform's primitives with a fixed byte pattern for random bytes, so AES's ivs repeat.
struct FixedRandomCrypto: PDFCryptoPrimitives {
    let base: any PDFCryptoPrimitives

    func md5(_ data: [UInt8]) -> [UInt8] {
        base.md5(data)
    }

    func sha2(_ data: [UInt8], bits: Int) throws -> [UInt8] {
        try base.sha2(data, bits: bits)
    }

    func rc4(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try base.rc4(key: key, data: data)
    }

    func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        try base.aesCBC(key: key, iv: iv, data: data, encrypt: encrypt)
    }

    func randomBytes(count: Int) throws -> [UInt8] {
        (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
    }
}
