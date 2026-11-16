import Foundation
#if canImport(PDFKit)
    import PDFKit
#endif
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

/// Revision 6 (AES-256) against a file `R6TestEncryption` wrote from `plain.pdf`. ssm reading its own file shows only
/// that the two sides agree; PDFKit, which derives the key its own way, opening it without a password and reading its
/// title is what shows Algorithm 2.B and the AESV3 method are the standard's. An R6 original from an independent
/// generator joins these once qpdf is on the machine (`Fixtures/Encrypted/README.md`).
@Suite(.enabled(if: PDFPlatformCrypto.primitives != nil))
struct PDFEncryptedR6Tests {
    /// Everything allowed, and printing only (no bit 6, so no annotations): bits 7, 8 and 13 to 32 are set as the
    /// standard asks.
    static let allowed = Int32(bitPattern: 0xFFFF_FFFC)
    static let printingOnly = Int32(bitPattern: 0xFFFF_F0C4)
    static let title = "Sample Title"

    private let crypto: any PDFCryptoPrimitives

    init() throws {
        crypto = try #require(PDFPlatformCrypto.primitives)
    }

    private func r6(permissions: Int32 = allowed) throws -> Data {
        try R6TestEncryption.encrypt(
            PDFEncryptedReadTests.fixture("plain"), owner: "owner-only", permissions: permissions, crypto: crypto,
        )
    }

    @Test func `ssm opens an R6 file with the empty password and reads its title and pages`() throws {
        let data = try r6()
        let document = try PDFSourceDocument(data, encryption: .decrypt(crypto))
        #expect(document.security?.revision == 6)
        #expect(document.security?.fileKey.count == 32)
        let reference = try #require(document.trailer["Info"])
        let info = try #require(try document.resolve(reference).dictionaryValue)
        #expect(try String(bytes: #require(info["Title"]?.stringBytes), encoding: .utf8) == Self.title)
        let plain = try PDFIncrementalAnnotator.pageBoxes(of: PDFEncryptedReadTests.fixture("plain"), crypto: nil)
        #expect(try PDFIncrementalAnnotator.pageBoxes(of: data, crypto: crypto) == plain)
        #expect(try PDFIncrementalAnnotator.permissions(of: r6(permissions: Self.printingOnly))?.allowsAnnotations
            == false)
    }

    @Test func `ink appended to an R6 file reads back through ssm`() throws {
        let output = try PDFIncrementalAnnotator.append([0: [PDFEncryptedAppendTests.ink]], to: r6(), crypto: crypto)
        let document = try PDFSourceDocument(output, encryption: .decrypt(crypto))
        let page = try #require(try document.pages().first)
        let annots = try #require(page.dictionary["Annots"])
        #expect(try document.resolve(annots).arrayValue?.count == 1)
    }

    #if canImport(PDFKit)
        @Test func `PDFKit opens the R6 file without a password and reads its title`() throws {
            let document = try #require(PDFDocument(data: r6()))
            let plain = try #require(PDFDocument(data: PDFEncryptedReadTests.fixture("plain")))
            #expect(document.isEncrypted)
            #expect(!document.isLocked)
            #expect(document.pageCount == plain.pageCount)
            #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == Self.title)
            #expect(document.allowsCommenting)
        }

        /// The owner password lifts the owner's restrictions: PDFKit checks `/O` (Algorithm 12), hashed over `/U`. Each
        /// password goes to a document of its own, and `unlock` is called once, outside `#expect`, which may evaluate
        /// its expression again to show it. `unlock` answers true for any password here — the empty user password has
        /// already opened the document (measured 2026-11-16) — so the rights are what tell the two apart.
        @Test func `PDFKit takes the owner password and no other`() throws {
            let data = try r6(permissions: Self.printingOnly)
            let wrong = try #require(PDFDocument(data: data))
            #expect(!wrong.allowsCommenting)
            #expect(wrong.allowsPrinting)
            _ = wrong.unlock(withPassword: "not-the-owner")
            #expect(!wrong.allowsCommenting)
            let owner = try #require(PDFDocument(data: data))
            let ownerUnlocks = owner.unlock(withPassword: "owner-only")
            #expect(ownerUnlocks)
            #expect(owner.allowsCommenting)
        }

        @Test func `PDFKit opens ink appended to the R6 file`() throws {
            let output = try PDFIncrementalAnnotator.append(
                [0: [PDFEncryptedAppendTests.ink]], to: r6(), crypto: crypto,
            )
            let document = try #require(PDFDocument(data: output))
            #expect(document.isEncrypted)
            #expect(!document.isLocked)
            let annotations = try #require(document.page(at: 0)).annotations
            #expect(annotations.count == 1)
            #expect(annotations.first?.type == "Ink")
            #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == Self.title)
        }
    #endif
}
