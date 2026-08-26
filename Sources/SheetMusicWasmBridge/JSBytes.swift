import JavaScriptKit
import SheetMusicFoundation

extension JSUint8Array {
    /// One bulk `swjs_load_typed_array` call, one copy.
    var bridgedData: Data {
        let count = length
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            copyMemory(to: raw.bindMemory(to: UInt8.self))
        }
        return data
    }
}

extension Data {
    /// One bulk `swjs_create_typed_array` call, one copy.
    var bridgedUint8Array: JSUint8Array {
        guard !isEmpty else { return JSUint8Array(length: 0) }
        return withUnsafeBytes { raw in
            JSUint8Array(buffer: raw.bindMemory(to: UInt8.self))
        }
    }
}
