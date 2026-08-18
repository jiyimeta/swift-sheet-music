import JavaScriptKit
import SheetMusicCore

/// This image's build identity. A host compares it with its own before it
/// trusts a cached layout or opens an edit session.
///
/// Android: `nativeEngineVersionStamp`, which returns the `Int64` directly.
///
/// The wasm surface returns the decimal string instead, and neither `Int` nor
/// `Int64` would do. `SheetMusicEngine.versionStamp` is a full 64-bit FNV-1a
/// digest of the version string, not a counter: `Int` is 32 bits on wasm32, so
/// converting traps, and truncating would throw away half of a value whose only
/// job is to differ when two builds differ. BridgeJS can lower `Int64` to a
/// JavaScript `bigint`, which is exact — but a `bigint` cannot be carried in
/// JSON, and the parity fixtures that pin this build against the Apple one are
/// JSON. A decimal string is exact, comparable with `===`, and survives the
/// round trip.
@JS public func engineVersionStamp() -> String {
    String(SheetMusicEngine.versionStamp)
}
