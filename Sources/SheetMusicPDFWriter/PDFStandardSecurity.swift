import SheetMusicPDFSyntax

/// The PDF standard security handler (ISO 32000-2 §7.6.4) for a file whose user password is empty — one anyone can
/// open, as a score's owner-password-only original is. It derives the file key from the empty password, checks that
/// password against the file (so a file that does need one is refused rather than misread), and gives each string and
/// stream its own key, for revisions 2 to 6 and the RC4, AES-128 and AES-256 methods.
///
/// Every rule here is portable; the cryptography itself is the caller's `PDFCryptoPrimitives`.
struct PDFStandardSecurity {
    /// How strings or streams are encrypted: a crypt filter's `/CFM`, or the method revisions 2 and 3 imply.
    enum Method: Equatable {
        case identity
        case rc4
        case aesV2
        case aesV3
    }

    let revision: Int
    /// The file encryption key: 5 to 16 bytes for RC4 and AES-128, 32 for AES-256.
    let fileKey: [UInt8]
    let streamMethod: Method
    let stringMethod: Method
    /// Whether the document's metadata stream is encrypted too (`/EncryptMetadata`, revision 4 and later).
    let encryptMetadata: Bool
    /// `/P`, the owner's permissions as the file states them (ISO 32000-2 Table 22).
    let permissions: Int32
    private let crypto: any PDFCryptoPrimitives

    /// Reads `encrypt` (the trailer's `/Encrypt` dictionary, resolved) with `documentID` (the first string of the
    /// trailer's `/ID`). Throws `.encrypted` for a handler or revision this does not implement, `.passwordRequired`
    /// when the empty user password does not open the file, `.unreadable` for a dictionary missing what its revision
    /// needs.
    init(encrypt: [String: PDFObject], documentID: [UInt8], crypto: any PDFCryptoPrimitives) throws {
        guard encrypt["Filter"]?.nameValue == "Standard",
              let version = encrypt["V"]?.integerValue, let revision = encrypt["R"]?.integerValue,
              (2 ... 6).contains(revision)
        else { throw PDFAppendError.encrypted }
        guard let owner = encrypt["O"]?.stringBytes, let user = encrypt["U"]?.stringBytes,
              let rawPermissions = encrypt["P"]?.integerValue
        else { throw PDFAppendError.unreadable }
        self.revision = revision
        self.crypto = crypto
        permissions = Int32(truncatingIfNeeded: rawPermissions)
        encryptMetadata = revision >= 4 ? encrypt["EncryptMetadata"]?.boolValue ?? true : true
        (streamMethod, stringMethod) = try Self.methods(encrypt, version: version)

        if revision <= 4 {
            let length = try Self.keyLength(encrypt, version: version, revision: revision)
            guard owner.count >= 32, user.count >= 32 else { throw PDFAppendError.unreadable }
            let key = Self.fileKey(
                owner: owner, permissions: permissions, documentID: documentID, length: length, revision: revision,
                encryptMetadata: encryptMetadata, crypto: crypto,
            )
            guard try Self.userPasswordOpens(key: key, user: user, documentID: documentID, revision: revision, crypto)
            else { throw PDFAppendError.passwordRequired }
            fileKey = key
        } else {
            guard user.count >= 48, let userKey = encrypt["UE"]?.stringBytes, userKey.count >= 32 else {
                throw PDFAppendError.unreadable
            }
            let validationSalt = Array(user[32 ..< 40])
            let keySalt = Array(user[40 ..< 48])
            guard try Self.hash(salt: validationSalt, revision: revision, crypto) == Array(user[0 ..< 32]) else {
                throw PDFAppendError.passwordRequired
            }
            let intermediate = try Self.hash(salt: keySalt, revision: revision, crypto)
            fileKey = try crypto.aesCBC(
                key: intermediate, iv: [UInt8](repeating: 0, count: 16), data: Array(userKey[0 ..< 32]),
                encrypt: false, padded: false,
            )
        }
    }

    // MARK: - Strings and streams

    /// `bytes` of object `number` `generation` decrypted by `method` (a string's or a stream's).
    func decrypt(_ bytes: [UInt8], number: Int, generation: Int, method: Method) throws -> [UInt8] {
        switch method {
        case .identity:
            return bytes
        case .rc4:
            return try crypto.rc4(key: objectKey(number: number, generation: generation, method: method), data: bytes)
        case .aesV2, .aesV3:
            // An empty string or stream stays empty; anything shorter than its iv is not AES output at all.
            guard !bytes.isEmpty else { return [] }
            guard bytes.count >= 16 else { throw PDFAppendError.unreadable }
            return try crypto.aesCBC(
                key: objectKey(number: number, generation: generation, method: method),
                iv: Array(bytes[0 ..< 16]), data: Array(bytes[16...]), encrypt: false, padded: true,
            )
        }
    }

    /// `bytes` encrypted by `method` for object `number` `generation`: AES gets a fresh iv in front.
    func encrypt(_ bytes: [UInt8], number: Int, generation: Int, method: Method) throws -> [UInt8] {
        switch method {
        case .identity:
            return bytes
        case .rc4:
            return try crypto.rc4(key: objectKey(number: number, generation: generation, method: method), data: bytes)
        case .aesV2, .aesV3:
            let iv = try crypto.randomBytes(count: 16)
            let body = try crypto.aesCBC(
                key: objectKey(number: number, generation: generation, method: method), iv: iv, data: bytes,
                encrypt: true, padded: true,
            )
            return iv + body
        }
    }

    /// Algorithm 1: the file key extended by the object's number and generation (and `sAlT` for AES), hashed and cut
    /// to at most 16 bytes. AES-256 uses the file key as it is.
    func objectKey(number: Int, generation: Int, method: Method) -> [UInt8] {
        if method == .aesV3 { return fileKey }
        var input = fileKey
        input += [
            UInt8(truncatingIfNeeded: number),
            UInt8(truncatingIfNeeded: number >> 8),
            UInt8(truncatingIfNeeded: number >> 16),
        ]
        input += [UInt8(truncatingIfNeeded: generation), UInt8(truncatingIfNeeded: generation >> 8)]
        if method == .aesV2 { input += [0x73, 0x41, 0x6C, 0x54] }
        return Array(crypto.md5(input).prefix(min(fileKey.count + 5, 16)))
    }

    // MARK: - Reading the dictionary

    /// The streams' and the strings' methods: revisions 2 and 3 (`/V` 1 or 2) are RC4 throughout; `/V` 4 and 5 name
    /// crypt filters in `/CF`, `/StmF` and `/StrF`, each `/Identity` unless named.
    private static func methods(_ encrypt: [String: PDFObject], version: Int) throws -> (Method, Method) {
        switch version {
        case 1, 2:
            return (.rc4, .rc4)
        case 4, 5:
            let filters = encrypt["CF"]?.dictionaryValue ?? [:]
            func method(_ key: String) throws -> Method {
                let name = encrypt[key]?.nameValue ?? "Identity"
                if name == "Identity" { return .identity }
                guard let filter = filters[name]?.dictionaryValue else { throw PDFAppendError.unreadable }
                switch filter["CFM"]?.nameValue ?? "None" {
                case "None": return .identity
                case "V2": return .rc4
                case "AESV2": return .aesV2
                case "AESV3": return .aesV3
                default: throw PDFAppendError.encrypted
                }
            }
            return try (method("StmF"), method("StrF"))
        default:
            throw PDFAppendError.encrypted
        }
    }

    /// The file key's length in bytes for revisions 2 to 4: 5 for revision 2; `/Length` bits for `/V` 2; the crypt
    /// filter's length (16 for AES-128) for `/V` 4.
    private static func keyLength(_ encrypt: [String: PDFObject], version: Int, revision: Int) throws -> Int {
        if revision == 2 { return 5 }
        if version == 4 { return 16 }
        let bits = encrypt["Length"]?.integerValue ?? 40
        guard bits >= 40, bits <= 128, bits % 8 == 0 else { throw PDFAppendError.unreadable }
        return bits / 8
    }

    // MARK: - Revisions 2 to 4

    /// The password padding string (ISO 32000-2 §7.6.4.3.2, Algorithm 2 step a): the empty password padded is this.
    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    /// Algorithm 2: MD5 of the padded (empty) password, `/O`, `/P` low byte first, the document ID and, at revision 4
    /// with metadata left clear, four 0xFF; rehashed 50 times from revision 3; cut to `length` bytes.
    static func fileKey(
        owner: [UInt8], permissions: Int32, documentID: [UInt8], length: Int, revision: Int, encryptMetadata: Bool,
        crypto: any PDFCryptoPrimitives,
    ) -> [UInt8] {
        let p = UInt32(bitPattern: permissions)
        var input = padding + Array(owner.prefix(32))
        input += [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)]
        input += documentID
        if revision >= 4, !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
        var hash = crypto.md5(input)
        if revision >= 3 {
            for _ in 0 ..< 50 {
                hash = crypto.md5(Array(hash.prefix(length)))
            }
        }
        return Array(hash.prefix(length))
    }

    /// Algorithms 4 and 5: the `/U` value the empty password would produce under `key`, compared with the file's.
    private static func userPasswordOpens(
        key: [UInt8], user: [UInt8], documentID: [UInt8], revision: Int, _ crypto: any PDFCryptoPrimitives,
    ) throws -> Bool {
        if revision == 2 {
            return try crypto.rc4(key: key, data: padding) == Array(user.prefix(32))
        }
        var value = try crypto.rc4(key: key, data: crypto.md5(padding + documentID))
        for round in 1 ... 19 {
            value = try crypto.rc4(key: key.map { $0 ^ UInt8(round) }, data: value)
        }
        return value == Array(user.prefix(16))
    }

    // MARK: - Revisions 5 and 6

    /// The hash of `password` with `salt` and, for an owner password, `userData` (the 48 bytes of `/U`): SHA-256
    /// alone at revision 5 (Adobe's extension level 3), and Algorithm 2.B's rounds of AES-128 and SHA-2 at revision
    /// 6. Opening a file needs only the empty user password; the tests' R6 writer hashes an owner password too.
    static func hash(
        password: [UInt8] = [], salt: [UInt8], userData: [UInt8] = [], revision: Int, _ crypto: any PDFCryptoPrimitives,
    ) throws -> [UInt8] {
        var key = try crypto.sha2(password + salt + userData, bits: 256)
        guard revision == 6 else { return key }
        var block: [UInt8] = [0]
        var round = 0
        while round < 64 || Int(block.last ?? 0) > round - 32 {
            let combined = password + key + userData
            let repeated = [UInt8](Array(repeating: combined, count: 64).joined())
            block = try crypto.aesCBC(
                key: Array(key[0 ..< 16]), iv: Array(key[16 ..< 32]), data: repeated, encrypt: true, padded: false,
            )
            let selector = block.prefix(16).reduce(0) { $0 + Int($1) } % 3
            key = try crypto.sha2(block, bits: [256, 384, 512][selector])
            round += 1
        }
        return Array(key.prefix(32))
    }
}
