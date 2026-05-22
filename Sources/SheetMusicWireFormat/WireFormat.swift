import Foundation

/// A type that can serialize itself into a `WireFormatWriter` in this
/// package's canonical little-endian binary form.
///
/// Conform manually for primitives, or apply `@WireFormat` to a struct to
/// have the macro emit a synthesized conformance whose layout is each
/// stored property encoded in declaration order.
public protocol WireFormatEncodable {
    func encode(into writer: inout WireFormatWriter)
}

/// A type that can be deserialized from a `WireFormatReader` in this
/// package's canonical little-endian binary form.
public protocol WireFormatDecodable {
    init(from reader: inout WireFormatReader) throws
}

public typealias WireFormat = WireFormatDecodable & WireFormatEncodable

extension WireFormatEncodable {
    /// Convenience: encode the value into a fresh writer and return the bytes.
    public func encodeToData() -> Data {
        var writer = WireFormatWriter()
        encode(into: &writer)
        return writer.data
    }
}

extension WireFormatDecodable {
    /// Convenience: decode the value from a self-contained byte buffer.
    /// Trailing bytes (if any) are tolerated.
    public init(decoding data: Data) throws {
        var reader = WireFormatReader(data: data)
        try self.init(from: &reader)
    }
}

/// Errors thrown while decoding wire-format payloads.
public enum WireFormatError: Error, Equatable {
    /// The reader needed `needed` bytes but only `remaining` were left.
    case truncated(needed: Int, remaining: Int)
    /// A length prefix decoded to a negative value (signed `Int32`).
    case invalidCount(Int32)
    /// String byte payload was not valid UTF-8.
    case invalidUTF8
}

/// Per-type override controlling how the external Kotlin codec
/// emitter (`emit-kotlin-codecs`) handles this type. The Swift macro
/// expansion ignores this argument — it's metadata for the external
/// tool only.
///
/// - `.auto`: resolve target Kotlin location via project config
///   (`kotlin-codegen.json`). Default when the argument is omitted.
/// - `.skip`: do not emit a Kotlin codec for this type. Use for types
///   that exist only in Swift-side flows.
/// - `.explicit(String)`: place the Kotlin codec at the given
///   fully-qualified package + class name, ignoring config rules.
public enum KotlinTarget: Sendable {
    case auto
    case skip
    case explicit(String)
}

/// Attach to a `struct` to synthesize a `WireFormat` conformance whose
/// encoding is each stored property in declaration order. All stored
/// property types must themselves conform to `WireFormat`.
///
/// Limitations (experimental scope):
/// - Target must be a `struct`. Classes, enums, actors are rejected with
///   a diagnostic.
/// - Computed properties are ignored. Stored properties with initializers
///   are still encoded — their wire bytes are the runtime value, not the
///   initializer expression.
/// - Property attributes other than access modifiers are not inspected.
@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormat() = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatMacro",
)

@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormat(kotlin: KotlinTarget) = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatMacro",
)

/// Attach to a `CaseIterable & Equatable` enum to synthesize a `WireFormat`
/// conformance whose encoding is the case's `allCases` ordinal as a single
/// `UInt8`. Caps at 256 cases.
///
/// Wire-stable as long as the order of cases in the source is preserved.
/// Adding a new case at the end is forward-compatible (old readers will
/// reject it with `invalidCount`); reordering or removing cases is a
/// breaking change to the wire layout.
@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormatEnum() = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatEnumMacro",
)

@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormatEnum(kotlin: KotlinTarget) = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatEnumMacro",
)

/// Attach to a sum-type enum (cases with associated values) to synthesize
/// a `WireFormat` conformance whose encoded layout is:
///
/// ```
/// u8 discriminator   ← case's declaration-order index (0, 1, 2, …)
/// payload            ← associated values of the selected case, encoded
///                      as WireFormat in declaration order
/// ```
///
/// All associated value types must conform to `WireFormat`. Cases without
/// associated values encode as just the discriminator byte.
///
/// Wire-stable contract: declaration order is the discriminator. Adding
/// a case at the end is forward-compatible (old readers throw
/// `WireFormatError.invalidCount`); reordering/removing cases is a
/// breaking wire change.
@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormatChoice() = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatChoiceMacro",
)

@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormatChoice(kotlin: KotlinTarget) = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatChoiceMacro",
)
