import SheetMusicWasmBridge

// PackageToJS packages an executable product, so the wasm module needs one.
// The `@JS` entry points live in `SheetMusicWasmBridge` because BridgeJS
// generates a thunk only for the target it is attached to, and those thunks
// survive into this image's export section without being referenced (verified
// against `WasmSizeProbe.wasm`). What does NOT survive on its own is the
// library archive: SwiftPM only links it if something in it is referenced.
// This call is that reference — and it is a real assertion, not a no-op, since
// a mismatched stamp means the wrong engine got linked.
precondition(engineVersionStamp() != 0, "engine version stamp must be non-zero")
