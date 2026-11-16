/// The five operations the PDF standard security handler is built from (ISO 32000-2 §7.6): two hashes, two ciphers and
/// a random source. Every rule of the handler — the file key from a password, the password's check, which objects are
/// encrypted, each object's own key — is portable Swift over these, written once in this target; only the operations
/// themselves come from a platform, so swift-sheet-music takes no cryptography dependency.
///
/// Apple and Windows supply them from their system libraries (`PDFPlatformCrypto.primitives`). Android's come from the
/// host app over JNI (its Kotlin `javax.crypto`), passed in by the caller, because this package has no way to call
/// Java. Where none is given, an encrypted file is refused as it always was (`PDFAppendError.encrypted`).
public protocol PDFCryptoPrimitives: Sendable {
    /// MD5 of `data` (16 bytes). The handler's revisions 2 to 4 derive keys with it; it protects nothing on its own.
    func md5(_ data: [UInt8]) -> [UInt8]

    /// SHA-256, SHA-384 or SHA-512 of `data` (`bits` 256, 384 or 512). Revision 6's key derivation alternates them.
    func sha2(_ data: [UInt8], bits: Int) throws -> [UInt8]

    /// RC4 of `data` under `key` (1 to 256 bytes). The same call encrypts and decrypts.
    func rc4(key: [UInt8], data: [UInt8]) throws -> [UInt8]

    /// AES in CBC mode, without padding, under a 16- or 32-byte `key` and a 16-byte `iv`; `data` is a whole number of
    /// 16-byte blocks. The PKCS #7 padding the handler's strings and streams carry is added and checked in portable
    /// code (`aesCBC(key:iv:data:encrypt:padded:)`), not by the platform: CommonCrypto, measured 2026-11-16, hands
    /// back a block whose padding does not check out instead of failing.
    func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8]

    /// `count` bytes from the platform's cryptographic random source: a new stream's initialization vector. Tests pass
    /// fixed bytes through their own conformer, so a written file can be compared byte for byte.
    func randomBytes(count: Int) throws -> [UInt8]
}

/// Why a cryptographic operation could not be carried out.
public enum PDFCryptoError: Error, Equatable, Sendable {
    /// A key, an initialization vector or a hash size the operation does not take.
    case invalidParameter
    /// Unpadded AES input that is not whole blocks, or padding that does not check out on decryption.
    case invalidData
    /// The platform's library refused the operation; `status` is its own code (CommonCrypto's or an NTSTATUS).
    case platformFailure(status: Int32)
}

/// The primitives this platform's system library provides, or nil where swift-sheet-music has none of its own
/// (Android, Linux, WebAssembly).
public enum PDFPlatformCrypto {
    public static var primitives: (any PDFCryptoPrimitives)? {
        #if canImport(CommonCrypto) && canImport(CryptoKit)
            AppleCryptoPrimitives()
        #elseif os(Windows)
            WindowsCryptoPrimitives()
        #else
            nil
        #endif
    }
}

extension PDFCryptoPrimitives {
    /// AES-CBC with PKCS #7 padding when `padded`: encrypting adds 1 to 16 bytes of padding (a whole block to whole
    /// blocks), decrypting checks and removes it, and padding that does not check out is `PDFCryptoError.invalidData`.
    /// Unpadded, it is the platform's call as it is.
    public func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool, padded: Bool) throws -> [UInt8] {
        guard padded else { return try aesCBC(key: key, iv: iv, data: data, encrypt: encrypt) }
        if encrypt {
            let count = 16 - data.count % 16
            return try aesCBC(
                key: key, iv: iv, data: data + [UInt8](repeating: UInt8(count), count: count), encrypt: true,
            )
        }
        guard !data.isEmpty else { throw PDFCryptoError.invalidData }
        let plain = try aesCBC(key: key, iv: iv, data: data, encrypt: false)
        guard let last = plain.last, (1 ... 16).contains(last), Int(last) <= plain.count,
              plain.suffix(Int(last)).allSatisfy({ $0 == last })
        else { throw PDFCryptoError.invalidData }
        return Array(plain.dropLast(Int(last)))
    }

    /// The parameter checks every conformer makes before calling its library, so they refuse the same inputs.
    func checkAES(key: [UInt8], iv: [UInt8], data: [UInt8]) throws {
        guard key.count == 16 || key.count == 32, iv.count == 16 else { throw PDFCryptoError.invalidParameter }
        guard data.count % 16 == 0 else { throw PDFCryptoError.invalidData }
    }

    func checkRC4(key: [UInt8]) throws {
        guard (1 ... 256).contains(key.count) else { throw PDFCryptoError.invalidParameter }
    }

    func checkSHA2(bits: Int) throws {
        guard [256, 384, 512].contains(bits) else { throw PDFCryptoError.invalidParameter }
    }
}
