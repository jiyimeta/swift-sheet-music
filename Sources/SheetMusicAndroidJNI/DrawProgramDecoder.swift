import Foundation

/// Swift-side decoder — testing only. The shipping decoder is the Kotlin
/// `DrawProgramDecoder` in Examples/Android/. Both must agree on the format
/// defined in DrawProgram.swift; keep them in lockstep.
public enum DrawProgramDecoder {
    public enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
        case unknownOpcode(UInt8)
    }

    public static func decode(_ data: Data) throws -> [EncodablePage] {
        var r = BinaryReader(data)
        let magic = r.read(UInt32.self)
        guard magic == DrawProgram.magic else {
            throw DecodeError.badMagic(magic)
        }
        let version = r.read(UInt32.self)
        guard version == DrawProgram.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        let pageCount = Int(r.read(UInt32.self))
        var pages: [EncodablePage] = []
        pages.reserveCapacity(pageCount)
        for _ in 0 ..< pageCount {
            try pages.append(decodePage(&r))
        }
        return pages
    }

    private static func decodePage(_ r: inout BinaryReader) throws -> EncodablePage {
        let w = r.readDouble()
        let h = r.readDouble()
        let count = Int(r.read(UInt32.self))
        var commands: [DrawCommand] = []
        commands.reserveCapacity(count)
        for _ in 0 ..< count {
            try commands.append(decodeCommand(&r))
        }
        return EncodablePage(widthMM: w, heightMM: h, commands: commands)
    }

    private static func decodeCommand(_ r: inout BinaryReader) throws -> DrawCommand {
        let opByte = r.read(UInt8.self)
        guard let op = DrawProgram.Opcode(rawValue: opByte) else {
            throw DecodeError.unknownOpcode(opByte)
        }
        switch op {
        case .moveTo:
            return .moveTo(x: r.readDouble(), y: r.readDouble())
        case .lineTo:
            return .lineTo(x: r.readDouble(), y: r.readDouble())
        case .stroke:
            return .stroke(width: r.readDouble())
        case .fillRect:
            return .fillRect(
                x: r.readDouble(),
                y: r.readDouble(),
                w: r.readDouble(),
                h: r.readDouble(),
            )
        case .glyph:
            let cp = r.read(UInt32.self)
            let x = r.readDouble()
            let y = r.readDouble()
            let size = r.readDouble()
            let fontId = DrawProgram.FontID(rawValue: r.read(UInt8.self)) ?? .textRoman
            return .glyph(codepoint: cp, x: x, y: y, size: size, fontId: fontId)
        case .text:
            let s = r.readUTF8()
            let x = r.readDouble()
            let y = r.readDouble()
            let size = r.readDouble()
            let fontId = DrawProgram.FontID(rawValue: r.read(UInt8.self)) ?? .textRoman
            return .text(s, x: x, y: y, size: size, fontId: fontId)
        }
    }
}
