enum KotlinTypeMap {
    /// Returns `(kotlinType, readerCall, writerCall(_:))` for a Swift
    /// primitive type. Calls use `r`/`w` as the cursor variable names.
    static func primitive(_ swiftType: String) -> (kotlinType: String, read: String, write: (String) -> String)? {
        switch swiftType {
        case "UInt8": return ("UByte", "r.readU8()", { "w.writeU8(\($0))" })
        case "Int8": return ("Byte", "r.readI8()", { "w.writeI8(\($0))" })
        case "UInt16": return ("UShort", "r.readU16()", { "w.writeU16(\($0))" })
        case "Int16": return ("Short", "r.readI16()", { "w.writeI16(\($0))" })
        case "UInt32": return ("UInt", "r.readU32()", { "w.writeU32(\($0))" })
        case "Int32": return ("Int", "r.readI32()", { "w.writeI32(\($0))" })
        case "UInt64": return ("ULong", "r.readU64()", { "w.writeU64(\($0))" })
        case "Int64": return ("Long", "r.readI64()", { "w.writeI64(\($0))" })
        case "Float": return ("Float", "r.readF32()", { "w.writeF32(\($0))" })
        case "Double": return ("Double", "r.readF64()", { "w.writeF64(\($0))" })
        case "Bool": return ("Boolean", "r.readU8() != 0u.toUByte()", { "w.writeU8(if (\($0)) 1u else 0u)" })
        // NOTE: BinaryReader/BinaryWriter in the existing Kotlin codebase do not yet
        // have readString()/writeString() methods (as of 2026-05-23). No current
        // @WireFormat type uses a raw String field, so this does not block codegen.
        // Task 17 will add readString/writeString and verify end-to-end.
        case "String": return ("String", "r.readString()", { "w.writeString(\($0))" })
        default:
            return nil
        }
    }

    /// Strips a Swift nested-type prefix (`Outer.Inner` → `Inner`). Codecs
    /// and model classes are emitted at top level, so namespace-qualified
    /// references in field / payload type text must be flattened before
    /// they become codec object names or import targets.
    static func simpleName(of typeText: String) -> String {
        guard let lastDot = typeText.lastIndex(of: ".") else { return typeText }
        return String(typeText[typeText.index(after: lastDot)...])
    }
}
