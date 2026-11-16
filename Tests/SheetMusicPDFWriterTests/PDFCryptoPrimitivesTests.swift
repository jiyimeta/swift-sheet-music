import SheetMusicPDFWriter
import Testing

/// The platform's primitives against published vectors, so the handler built on them can trust them: RFC 1321's MD5,
/// FIPS 180-2's SHA-2 examples ("abc"), RC4's widely quoted plaintext vectors, and NIST SP 800-38A's AES-CBC (F.2.1
/// AES-128, F.2.5 AES-256). Runs wherever swift-sheet-music has primitives of its own (Apple, Windows).
@Suite(.enabled(if: PDFPlatformCrypto.primitives != nil))
struct PDFCryptoPrimitivesTests {
    private let crypto: any PDFCryptoPrimitives

    init() throws {
        crypto = try #require(PDFPlatformCrypto.primitives)
    }

    private static func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else { preconditionFailure("not hex: \(text)") }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static let nistIV = hex("000102030405060708090a0b0c0d0e0f")
    private static let nistPlain = hex("6bc1bee22e409f96e93d7e117393172a")

    @Test func `MD5 matches RFC 1321`() {
        #expect(crypto.md5([]) == Self.hex("d41d8cd98f00b204e9800998ecf8427e"))
        #expect(crypto.md5(Array("abc".utf8)) == Self.hex("900150983cd24fb0d6963f7d28e17f72"))
    }

    @Test func `SHA-2 matches FIPS 180-2 on abc`() throws {
        let abc = Array("abc".utf8)
        #expect(try crypto.sha2(abc, bits: 256)
            == Self.hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(try crypto.sha2(abc, bits: 384) == Self.hex(
            "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
        ))
        #expect(try crypto.sha2(abc, bits: 512) == Self.hex(
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        ))
        #expect(throws: PDFCryptoError.invalidParameter) { try crypto.sha2(abc, bits: 224) }
    }

    @Test(arguments: [
        ("Key", "Plaintext", "bbf316e8d940af0ad3"),
        ("Wiki", "pedia", "1021bf0420"),
        ("Secret", "Attack at dawn", "45a01f645fc35b383552544b9bf5"),
    ])
    func `RC4 matches the published vectors and undoes itself`(key: String, plain: String, cipher: String) throws {
        let encrypted = try crypto.rc4(key: Array(key.utf8), data: Array(plain.utf8))
        #expect(encrypted == Self.hex(cipher))
        #expect(try crypto.rc4(key: Array(key.utf8), data: encrypted) == Array(plain.utf8))
    }

    @Test func `RC4 refuses an empty key`() {
        #expect(throws: PDFCryptoError.invalidParameter) { try crypto.rc4(key: [], data: [1]) }
    }

    @Test(arguments: [
        ("2b7e151628aed2a6abf7158809cf4f3c", "7649abac8119b246cee98e9b12e9197d"),
        ("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", "f58c4c04d6e5f1ba779eabfb5f7bfbd6"),
    ])
    func `AES-CBC matches NIST SP 800-38A unpadded, both ways`(key: String, cipher: String) throws {
        let encrypted = try crypto.aesCBC(
            key: Self.hex(key), iv: Self.nistIV, data: Self.nistPlain, encrypt: true, padded: false,
        )
        #expect(encrypted == Self.hex(cipher))
        let decrypted = try crypto.aesCBC(
            key: Self.hex(key), iv: Self.nistIV, data: encrypted, encrypt: false, padded: false,
        )
        #expect(decrypted == Self.nistPlain)
    }

    /// The handler's streams and strings are padded (PKCS #7): a whole block gains a block of padding, which
    /// decryption removes; the first block is still the unpadded vector's.
    @Test func `padded AES adds a whole block to a whole block and takes it off again`() throws {
        let key = Self.hex("2b7e151628aed2a6abf7158809cf4f3c")
        let encrypted = try crypto.aesCBC(key: key, iv: Self.nistIV, data: Self.nistPlain, encrypt: true, padded: true)
        #expect(encrypted.count == 32)
        #expect(Array(encrypted.prefix(16)) == Self.hex("7649abac8119b246cee98e9b12e9197d"))
        #expect(try crypto.aesCBC(key: key, iv: Self.nistIV, data: encrypted, encrypt: false, padded: true)
            == Self.nistPlain)
        let odd = Array("seven bytes".utf8)
        let round = try crypto.aesCBC(key: key, iv: Self.nistIV, data: odd, encrypt: true, padded: true)
        #expect(round.count == 16)
        #expect(try crypto.aesCBC(key: key, iv: Self.nistIV, data: round, encrypt: false, padded: true) == odd)
    }

    @Test func `AES refuses a wrong key or iv, and unpadded input that is not whole blocks`() {
        let key = Self.hex("2b7e151628aed2a6abf7158809cf4f3c")
        #expect(throws: PDFCryptoError.invalidParameter) {
            try crypto.aesCBC(key: [1, 2, 3], iv: Self.nistIV, data: Self.nistPlain, encrypt: true, padded: false)
        }
        #expect(throws: PDFCryptoError.invalidParameter) {
            try crypto.aesCBC(key: key, iv: [0], data: Self.nistPlain, encrypt: true, padded: false)
        }
        #expect(throws: PDFCryptoError.invalidData) {
            try crypto.aesCBC(key: key, iv: Self.nistIV, data: [1, 2, 3], encrypt: true, padded: false)
        }
    }

    /// A block that decrypts to bytes ending in no valid PKCS #7 padding is bad data, not a platform failure.
    @Test func `padding that does not check out is invalid data`() throws {
        let key = Self.hex("2b7e151628aed2a6abf7158809cf4f3c")
        // The NIST ciphertext block decrypts (unpadded) to the plaintext, whose last byte 0x2a is not a padding length.
        #expect(throws: PDFCryptoError.invalidData) {
            try crypto.aesCBC(
                key: key, iv: Self.nistIV, data: Self.hex("7649abac8119b246cee98e9b12e9197d"), encrypt: false,
                padded: true,
            )
        }
    }

    @Test func `random bytes come in the asked count and differ between calls`() throws {
        let first = try crypto.randomBytes(count: 16)
        let second = try crypto.randomBytes(count: 16)
        #expect(first.count == 16)
        #expect(first != second)
        #expect(try crypto.randomBytes(count: 0).isEmpty)
    }
}
