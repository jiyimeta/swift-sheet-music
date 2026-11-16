#if os(Windows)
    import WinSDK

    /// `PDFCryptoPrimitives` from Windows' Cryptography API: Next Generation (bcrypt.dll), which every supported
    /// Windows ships: `BCryptHash` for MD5 and SHA-2, a symmetric key for RC4 and for AES in CBC mode, and
    /// `BCryptGenRandom`. No C shim — the calls are plain C entry points, linked through the manifest's `bcrypt`.
    struct WindowsCryptoPrimitives: PDFCryptoPrimitives {
        func md5(_ data: [UInt8]) -> [UInt8] {
            // MD5 cannot fail on a valid provider; a failure here is a broken system, which the empty answer surfaces
            // as a key that opens nothing rather than a crash.
            (try? hash("MD5", data, length: 16)) ?? []
        }

        func sha2(_ data: [UInt8], bits: Int) throws -> [UInt8] {
            try checkSHA2(bits: bits)
            return try hash("SHA\(bits)", data, length: bits / 8)
        }

        func rc4(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
            try checkRC4(key: key)
            return try withKey("RC4", chaining: nil, key: key) { handle in
                try run(BCryptEncrypt, handle, data, iv: nil, flags: 0)
            }
        }

        func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
            try checkAES(key: key, iv: iv, data: data)
            return try withKey("AES", chaining: "ChainingModeCBC", key: key) { handle in
                try run(encrypt ? BCryptEncrypt : BCryptDecrypt, handle, data, iv: iv, flags: 0)
            }
        }

        func randomBytes(count: Int) throws -> [UInt8] {
            guard count >= 0 else { throw PDFCryptoError.invalidParameter }
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBufferPointer { buffer in
                BCryptGenRandom(nil, buffer.baseAddress, ULONG(count), ULONG(BCRYPT_USE_SYSTEM_PREFERRED_RNG))
            }
            try Self.check(status)
            return bytes
        }

        // MARK: - CNG

        private static func check(_ status: NTSTATUS) throws {
            guard status >= 0 else { throw PDFCryptoError.platformFailure(status: Int32(status)) }
        }

        /// Opens `algorithm`'s provider (by its CNG name: "MD5", "SHA256", "RC4", "AES"), runs `body`, closes it.
        private func withProvider<T>(_ algorithm: String, flags: ULONG = 0, _ body: (BCRYPT_ALG_HANDLE) throws -> T)
            throws -> T
        {
            var provider: BCRYPT_ALG_HANDLE?
            let status = algorithm.withCString(encodedAs: UTF16.self) { name in
                BCryptOpenAlgorithmProvider(&provider, name, nil, flags)
            }
            try Self.check(status)
            guard let provider else { throw PDFCryptoError.platformFailure(status: Int32(status)) }
            defer { _ = BCryptCloseAlgorithmProvider(provider, 0) }
            return try body(provider)
        }

        private func hash(_ algorithm: String, _ data: [UInt8], length: Int) throws -> [UInt8] {
            try withProvider(algorithm) { provider in
                var digest = [UInt8](repeating: 0, count: length)
                var input = data
                let status = input.withUnsafeMutableBufferPointer { inputBuffer in
                    digest.withUnsafeMutableBufferPointer { digestBuffer in
                        BCryptHash(
                            provider, nil, 0, inputBuffer.baseAddress, ULONG(data.count), digestBuffer.baseAddress,
                            ULONG(length),
                        )
                    }
                }
                try Self.check(status)
                return digest
            }
        }

        /// A symmetric key over `key`, its provider set to `chaining` first when given, for `body`'s calls.
        private func withKey<T>(
            _ algorithm: String, chaining: String?, key: [UInt8], _ body: (BCRYPT_KEY_HANDLE) throws -> T,
        ) throws -> T {
            try withProvider(algorithm) { provider in
                if let chaining {
                    var value = Array(chaining.utf16) + [0]
                    let status = "ChainingMode".withCString(encodedAs: UTF16.self) { property in
                        value.withUnsafeMutableBytes { bytes in
                            BCryptSetProperty(
                                provider, property, bytes.baseAddress?.assumingMemoryBound(to: UCHAR.self),
                                ULONG(bytes.count), 0,
                            )
                        }
                    }
                    try Self.check(status)
                }
                var handle: BCRYPT_KEY_HANDLE?
                var secret = key
                let status = secret.withUnsafeMutableBufferPointer { secretBuffer in
                    BCryptGenerateSymmetricKey(provider, &handle, nil, 0, secretBuffer.baseAddress, ULONG(key.count), 0)
                }
                try Self.check(status)
                guard let handle else { throw PDFCryptoError.platformFailure(status: Int32(status)) }
                defer { _ = BCryptDestroyKey(handle) }
                return try body(handle)
            }
        }

        private typealias CryptCall = (
            BCRYPT_KEY_HANDLE?, PUCHAR?, ULONG, UnsafeMutableRawPointer?, PUCHAR?, ULONG, PUCHAR?, ULONG,
            UnsafeMutablePointer<ULONG>?, ULONG,
        ) -> NTSTATUS

        /// `BCryptEncrypt` or `BCryptDecrypt`: asks for the output size, then runs. CNG overwrites the iv buffer with
        /// the chaining state, so it is given a copy.
        private func run(
            _ call: CryptCall, _ handle: BCRYPT_KEY_HANDLE, _ data: [UInt8], iv: [UInt8]?, flags: ULONG,
        ) throws -> [UInt8] {
            var input = data
            var chain = iv ?? []
            var needed: ULONG = 0
            var status = input.withUnsafeMutableBufferPointer { inputBuffer in
                chain.withUnsafeMutableBufferPointer { ivBuffer in
                    call(
                        handle, inputBuffer.baseAddress, ULONG(data.count), nil,
                        iv == nil ? nil : ivBuffer.baseAddress, ULONG(ivBuffer.count), nil, 0, &needed, flags,
                    )
                }
            }
            try Self.check(status)
            var output = [UInt8](repeating: 0, count: Int(needed))
            var written: ULONG = 0
            chain = iv ?? []
            status = input.withUnsafeMutableBufferPointer { inputBuffer in
                chain.withUnsafeMutableBufferPointer { ivBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        call(
                            handle, inputBuffer.baseAddress, ULONG(data.count), nil,
                            iv == nil ? nil : ivBuffer.baseAddress, ULONG(ivBuffer.count), outputBuffer.baseAddress,
                            ULONG(outputBuffer.count), &written, flags,
                        )
                    }
                }
            }
            try Self.check(status)
            return Array(output.prefix(Int(written)))
        }
    }
#endif
