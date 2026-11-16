import Foundation
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

/// Reading an encrypted original whose user password is empty (the standard security handler, revisions 2 to 4 here),
/// against files other generators encrypted: pypdf's RC4 and CoreGraphics' AES-128 (`Fixtures/Encrypted/README.md`
/// says how each was made). A wrong file key or method would leave the Info dictionary's title as noise, so the title
/// each generator wrote is the check that the key and the cipher are right.
@Suite(.enabled(if: PDFPlatformCrypto.primitives != nil))
struct PDFEncryptedReadTests {
    private let crypto: any PDFCryptoPrimitives

    init() throws {
        crypto = try #require(PDFPlatformCrypto.primitives)
    }

    static func fixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(contentsOf: folder.appendingPathComponent("Fixtures/Encrypted/\(name).pdf"))
    }

    private func open(_ name: String) throws -> PDFSourceDocument {
        try PDFSourceDocument(Self.fixture(name), encryption: .decrypt(crypto))
    }

    @Test(arguments: [
        ("rc4-40", 2, "Sample Title"),
        ("rc4-128", 3, "Sample Title"),
        ("aes128-allowed", 4, "folino fixture"),
    ])
    func `the empty password opens it and its strings decrypt to the generator's text`(
        name: String, revision: Int, title: String,
    ) throws {
        let document = try open(name)
        #expect(document.security?.revision == revision)
        let reference = try #require(document.trailer["Info"])
        let info = try #require(try document.resolve(reference).dictionaryValue)
        let bytes = try #require(info["Title"]?.stringBytes)
        #expect(String(bytes: bytes, encoding: .utf8) == title)
    }

    @Test(arguments: ["rc4-40", "rc4-128", "aes128-allowed"])
    func `an encrypted original's pages read as the unencrypted original's`(name: String) throws {
        let plain = try PDFIncrementalAnnotator.pageBoxes(of: Self.fixture("plain"), crypto: nil)
        #expect(try PDFIncrementalAnnotator.pageBoxes(of: Self.fixture(name), crypto: crypto).count >= 1)
        #expect(try PDFIncrementalAnnotator.pageBoxes(of: Self.fixture(name), crypto: crypto).first == plain.first)
    }

    @Test func `a file that needs a user password is refused as such`() {
        #expect(throws: PDFAppendError.passwordRequired) { try open("aes128-user-password") }
    }

    @Test func `without primitives an encrypted file is refused as it always was`() throws {
        #expect(throws: PDFAppendError.encrypted) {
            try PDFIncrementalAnnotator.pageSizes(of: Self.fixture("aes128-allowed"), crypto: nil)
        }
    }

    @Test func `the permissions are read without a key`() throws {
        let allowed = try #require(try PDFIncrementalAnnotator.permissions(of: Self.fixture("aes128-allowed")))
        let forbidden = try #require(try PDFIncrementalAnnotator.permissions(of: Self.fixture("aes128-forbidden")))
        #expect(allowed.allowsAnnotations)
        #expect(!forbidden.allowsAnnotations)
        #expect(forbidden.allowsPrinting)
        #expect(try PDFIncrementalAnnotator.permissions(of: Self.fixture("aes128-user-password")) != nil)
        #expect(try PDFIncrementalAnnotator.permissions(of: Self.fixture("plain")) == nil)
    }

    /// Until the writer encrypts what it adds, appending to an encrypted original stays refused: a clear object in an
    /// encrypted file is one no reader can open. (Nothing to add hands the original back untouched, so the refusal
    /// needs a real mark to show.)
    @Test func `appending to an encrypted original is still refused`() throws {
        #expect(throws: PDFAppendError.encrypted) {
            try PDFIncrementalAnnotator.append(
                [0: [PDFPageAnnotationTests.ink(x: 20, y: 30)]], to: Self.fixture("aes128-allowed"),
            )
        }
    }

    /// Each method's own round trip, under the file key of a real file: AES gets a fresh iv each time, so the same
    /// string encrypts differently twice and still decrypts to itself. Under another object's key RC4 gives noise and
    /// AES almost always fails its padding check (`invalidData`); either way the text does not come back.
    @Test(arguments: ["rc4-128", "aes128-allowed"])
    func `strings round-trip under each method`(name: String) throws {
        let security = try #require(try open(name).security)
        let text = Array("an annotation's contents".utf8)
        let first = try security.encrypt(text, number: 12, generation: 0, method: security.stringMethod)
        let second = try security.encrypt(text, number: 12, generation: 0, method: security.stringMethod)
        #expect(try security.decrypt(first, number: 12, generation: 0, method: security.stringMethod) == text)
        #expect(try security.decrypt(second, number: 12, generation: 0, method: security.stringMethod) == text)
        #expect((first == second) == (security.stringMethod == .rc4))
        #expect((try? security.decrypt(first, number: 13, generation: 0, method: security.stringMethod)) != text)
    }

    @Test func `an object's key is the file key plus five bytes, at most sixteen`() throws {
        let rc440 = try #require(try open("rc4-40").security)
        let aes = try #require(try open("aes128-allowed").security)
        #expect(rc440.fileKey.count == 5)
        #expect(rc440.objectKey(number: 7, generation: 0, method: .rc4).count == 10)
        #expect(aes.fileKey.count == 16)
        #expect(aes.objectKey(number: 7, generation: 0, method: .aesV2).count == 16)
        #expect(aes.objectKey(number: 7, generation: 0, method: .aesV2)
            != aes.objectKey(number: 7, generation: 0, method: .rc4))
    }
}
