import Foundation
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter

/// Rewrites an unencrypted PDF encrypted by the standard security handler at revision 6 (AES-256, ISO 32000-2
/// §7.6.4.4) with an empty user password and `owner` as the owner password: the shape of an R6 owner-password-only
/// original. Tests only. No AES-256 generator is on the machine yet — CoreGraphics refuses 256 bits and qpdf is not
/// installed — so the R6 key derivation is checked by handing this file to PDFKit, which derives the key its own way:
/// were Algorithm 2.B wrong here, ssm would still open its own file, and PDFKit would not.
///
/// Every object is rewritten top-level at generation 0, so the original must keep none in an object stream.
enum R6TestEncryption {
    struct ObjectStreamsUnsupported: Error {}

    static func encrypt(
        _ plain: Data, owner: String, permissions: Int32, crypto: any PDFCryptoPrimitives,
    ) throws -> Data {
        let source = try PDFSourceDocument(plain)
        let compressed = source.locations.values.contains {
            if case .compressed = $0 { true } else { false }
        }
        guard !compressed else { throw ObjectStreamsUnsupported() }
        let encrypt = try dictionary(owner: owner, permissions: permissions, crypto: crypto)
        let documentID = try source.trailer["ID"]?.arrayValue?.first?.stringBytes ?? crypto.randomBytes(count: 16)
        let security = try PDFStandardSecurity(encrypt: encrypt, documentID: documentID, crypto: crypto)

        var bytes = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var offsets: [Int: Int] = [:]
        for number in 1 ..< source.size {
            guard case .offset = source.locations[number] else { continue }
            let value = try PDFIncrementalAnnotator.encrypted(
                source.object(number), number: number, generation: 0, security: security,
            )
            offsets[number] = bytes.count
            bytes += Array("\(number) 0 obj\n".utf8)
            if case let .stream(entries, raw) = value {
                let payload = try security.encrypt(raw, number: number, generation: 0, method: security.streamMethod)
                var dictionary = entries
                dictionary["Length"] = .int(payload.count)
                bytes += Array("\(PDFObject.dictionary(dictionary).serialized)\nstream\n".utf8) + payload
                bytes += Array("\nendstream\nendobj\n".utf8)
            } else {
                bytes += Array("\(value.serialized)\nendobj\n".utf8)
            }
        }
        // The encryption dictionary's strings are never encrypted.
        let encryptNumber = source.size
        offsets[encryptNumber] = bytes.count
        bytes += Array("\(encryptNumber) 0 obj\n\(PDFObject.dictionary(encrypt).serialized)\nendobj\n".utf8)

        let table = bytes.count
        var text = "xref\n0 \(encryptNumber + 1)\n0000000000 65535 f \n"
        for number in 1 ... encryptNumber {
            let offset = String(offsets[number] ?? 0)
            let padded = String(repeating: "0", count: 10 - offset.count) + offset
            text += offsets[number] == nil ? "0000000000 00000 f \n" : "\(padded) 00000 n \n"
        }
        var trailer: [String: PDFObject] = [
            "Size": .int(encryptNumber + 1),
            "Encrypt": .reference(encryptNumber, 0),
            "ID": .array([.string(documentID), .string(documentID)]),
        ]
        trailer["Root"] = source.trailer["Root"]
        trailer["Info"] = source.trailer["Info"]
        text += "trailer\n\(PDFObject.dictionary(trailer).serialized)\nstartxref\n\(table)\n%%EOF\n"
        return Data(bytes + Array(text.utf8))
    }

    /// Algorithms 8, 9 and 10: `/U` and `/UE` from the empty user password, `/O` and `/OE` from `owner` over `/U`, and
    /// `/Perms` — `/P`, "T" (metadata encrypted) and "adb" in one block under a fresh 32-byte file key.
    private static func dictionary(
        owner: String, permissions: Int32, crypto: any PDFCryptoPrimitives,
    ) throws -> [String: PDFObject] {
        let zero = [UInt8](repeating: 0, count: 16)
        let fileKey = try crypto.randomBytes(count: 32)
        let salts = try crypto.randomBytes(count: 32)
        let userValidation = Array(salts[0 ..< 8])
        let userKeySalt = Array(salts[8 ..< 16])
        let ownerValidation = Array(salts[16 ..< 24])
        let ownerKeySalt = Array(salts[24 ..< 32])

        let user = try PDFStandardSecurity.hash(salt: userValidation, revision: 6, crypto) + userValidation
            + userKeySalt
        let userKey = try crypto.aesCBC(
            key: PDFStandardSecurity.hash(salt: userKeySalt, revision: 6, crypto), iv: zero, data: fileKey,
            encrypt: true, padded: false,
        )
        let password = Array(owner.utf8)
        let ownerValue = try PDFStandardSecurity.hash(
            password: password, salt: ownerValidation, userData: user, revision: 6, crypto,
        ) + ownerValidation + ownerKeySalt
        let ownerKey = try crypto.aesCBC(
            key: PDFStandardSecurity.hash(password: password, salt: ownerKeySalt, userData: user, revision: 6, crypto),
            iv: zero, data: fileKey, encrypt: true, padded: false,
        )
        let p = UInt32(bitPattern: permissions)
        let block = try [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)]
            + [0xFF, 0xFF, 0xFF, 0xFF, 0x54, 0x61, 0x64, 0x62] + crypto.randomBytes(count: 4)
        // One block of AES-256-ECB is CBC with a zero iv.
        let perms = try crypto.aesCBC(key: fileKey, iv: zero, data: block, encrypt: true, padded: false)
        return [
            "Filter": .name("Standard"), "V": .int(5), "R": .int(6), "Length": .int(256),
            "CF": .dictionary([
                "StdCF": .dictionary(["AuthEvent": .name("DocOpen"), "CFM": .name("AESV3"), "Length": .int(32)]),
            ]),
            "StmF": .name("StdCF"), "StrF": .name("StdCF"),
            "O": .string(ownerValue), "U": .string(user), "OE": .string(ownerKey), "UE": .string(userKey),
            "Perms": .string(perms), "P": .int(Int(permissions)),
        ]
    }
}
