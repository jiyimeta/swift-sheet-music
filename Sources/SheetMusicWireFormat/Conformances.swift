import Foundation

// MARK: - Fixed-width integer conformances
//
// Swift's protocol-extension mechanism cannot conform a generic
// `FixedWidthInteger` to a concrete protocol with member requirements,
// so each scalar type gets a trivial dedicated conformance.

extension UInt8: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension UInt8: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(UInt8.self)
    }
}

extension UInt16: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension UInt16: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(UInt16.self)
    }
}

extension UInt32: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension UInt32: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(UInt32.self)
    }
}

extension UInt64: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension UInt64: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(UInt64.self)
    }
}

extension Int8: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension Int8: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(Int8.self)
    }
}

extension Int16: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension Int16: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(Int16.self)
    }
}

extension Int32: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension Int32: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(Int32.self)
    }
}

extension Int64: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(self)
    }
}

extension Int64: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(Int64.self)
    }
}

// MARK: - Bool — 1 byte (0 = false, anything else = true).

extension Bool: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(UInt8(self ? 1 : 0))
    }
}

extension Bool: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try reader.readInteger(UInt8.self) != 0
    }
}

// MARK: - Float / Double — IEEE 754 little-endian via bitPattern.

extension Float: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(bitPattern)
    }
}

extension Float: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try Float(bitPattern: reader.readInteger(UInt32.self))
    }
}

extension Double: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(bitPattern)
    }
}

extension Double: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        self = try Double(bitPattern: reader.readInteger(UInt64.self))
    }
}

// MARK: - String — Int32 byte-length prefix + UTF-8 bytes.

extension String: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        let bytes = Array(utf8)
        writer.appendInteger(Int32(bytes.count))
        writer.appendBytes(bytes)
    }
}

extension String: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        let count = try reader.readInteger(Int32.self)
        guard count >= 0 else { throw WireFormatError.invalidCount(count) }
        let bytes = try reader.readBytes(count: Int(count))
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw WireFormatError.invalidUTF8
        }
        self = s
    }
}

// MARK: - Array — Int32 element-count prefix + elements in order.

extension Array: WireFormatEncodable where Element: WireFormatEncodable {
    public func encode(into writer: inout WireFormatWriter) {
        writer.appendInteger(Int32(count))
        for element in self {
            element.encode(into: &writer)
        }
    }
}

extension Array: WireFormatDecodable where Element: WireFormatDecodable {
    public init(from reader: inout WireFormatReader) throws {
        let count = try reader.readInteger(Int32.self)
        guard count >= 0 else { throw WireFormatError.invalidCount(count) }
        var result = [Element]()
        result.reserveCapacity(Int(count))
        for _ in 0 ..< Int(count) {
            try result.append(Element(from: &reader))
        }
        self = result
    }
}
