import JavaScriptKit
import SheetMusicFoundation
@testable import SheetMusicWasmBridge

/// Builds the argument the byte-blob entry points now take, in one bulk copy.
///
/// Deliberately no `==` overload for `JSUint8Array`: it is a `JSObject`
/// subclass, so a free operator competing with the identity comparison it
/// inherits would decide by overload resolution which one an assertion got.
/// Tests that compare contents say `.bridgedData` and compare `Data`.
func jsBytes(_ bytes: [UInt8]) -> JSUint8Array {
    JSUint8Array(bytes)
}

func jsBytes(_ data: Data) -> JSUint8Array {
    JSUint8Array(Array(data))
}

/// Read-only conveniences so an assertion about a returned blob reads the way
/// it did when these entry points returned `[UInt8]`. `prefix` and
/// `contains(where:)` each copy the whole array out of JavaScript, which is
/// fine for a test and would not be in production code.
extension JSUint8Array {
    var count: Int {
        length
    }

    var isEmpty: Bool {
        length == 0
    }

    func prefix(_ maxLength: Int) -> [UInt8] {
        Array(bridgedData.prefix(maxLength))
    }

    func contains(where predicate: (UInt8) throws -> Bool) rethrows -> Bool {
        try bridgedData.contains(where: predicate)
    }
}
