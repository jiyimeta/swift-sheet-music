#if canImport(CommonCrypto) && canImport(CryptoKit)
    import CommonCrypto
    import CryptoKit
    import Foundation
    import Security

    /// `PDFCryptoPrimitives` from Apple's system libraries: CryptoKit for the hashes (`Insecure.MD5`, SHA-2),
    /// CommonCrypto for the two ciphers, which CryptoKit does not offer (RC4, AES-CBC), and `SecRandomCopyBytes`.
    struct AppleCryptoPrimitives: PDFCryptoPrimitives {
        func md5(_ data: [UInt8]) -> [UInt8] {
            Array(Insecure.MD5.hash(data: data))
        }

        func sha2(_ data: [UInt8], bits: Int) throws -> [UInt8] {
            try checkSHA2(bits: bits)
            return switch bits {
            case 256: Array(SHA256.hash(data: data))
            case 384: Array(SHA384.hash(data: data))
            default: Array(SHA512.hash(data: data))
            }
        }

        func rc4(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
            try checkRC4(key: key)
            return try crypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmRC4), options: 0, key: key, iv: nil, data: data,
            )
        }

        func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
            try checkAES(key: key, iv: iv, data: data)
            return try crypt(
                CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options: 0, key: key,
                iv: iv, data: data,
            )
        }

        func randomBytes(count: Int) throws -> [UInt8] {
            guard count >= 0 else { throw PDFCryptoError.invalidParameter }
            guard count > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBytes { buffer in
                buffer.baseAddress.map { SecRandomCopyBytes(kSecRandomDefault, count, $0) } ?? errSecParam
            }
            guard status == errSecSuccess else { throw PDFCryptoError.platformFailure(status: status) }
            return bytes
        }

        /// One `CCCrypt` call: CBC is CommonCrypto's default mode for a block cipher, and RC4 ignores the mode and
        /// the iv.
        private func crypt(
            _ operation: CCOperation, _ algorithm: CCAlgorithm, options: CCOptions, key: [UInt8], iv: [UInt8]?,
            data: [UInt8],
        ) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
            var moved = 0
            let outputCapacity = output.count
            let status = output.withUnsafeMutableBytes { out in
                key.withUnsafeBytes { keyBytes in
                    data.withUnsafeBytes { input in
                        if let iv {
                            iv.withUnsafeBytes { ivBytes in
                                CCCrypt(
                                    operation, algorithm, options, keyBytes.baseAddress, key.count,
                                    ivBytes.baseAddress, input.baseAddress, data.count, out.baseAddress,
                                    outputCapacity, &moved,
                                )
                            }
                        } else {
                            CCCrypt(
                                operation, algorithm, options, keyBytes.baseAddress, key.count, nil,
                                input.baseAddress, data.count, out.baseAddress, outputCapacity, &moved,
                            )
                        }
                    }
                }
            }
            guard status == kCCSuccess else { throw PDFCryptoError.platformFailure(status: status) }
            return Array(output.prefix(moved))
        }
    }
#endif
