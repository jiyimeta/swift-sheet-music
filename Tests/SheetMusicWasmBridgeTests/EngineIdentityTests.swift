import SheetMusicCore
@testable import SheetMusicWasmBridge
import Testing

/// Runs under `swift package --swift-sdk swift-6.3.3-RELEASE_wasm js test`.
/// The suite deliberately builds every input in memory: a wasm test host has no
/// preopened directory unless one is passed, so a fixture file would make the
/// suite depend on how it was launched.
@Suite("engine identity")
struct EngineIdentityTests {
    @Test("the stamp matches the engine's own constant")
    func stampMatchesEngine() {
        #expect(engineVersionStamp() == String(SheetMusicEngine.versionStamp))
    }

    @Test("the stamp is not empty")
    func stampIsNotEmpty() {
        #expect(!engineVersionStamp().isEmpty)
    }

    /// `Int` is 32 bits on wasm32 and the stamp is a 64-bit digest, so a
    /// narrowing surface would either trap or silently halve it. Reading the
    /// string back as `Int64` pins that the whole value survived.
    @Test("the stamp survives the string round trip as a 64-bit value")
    func stampRoundTripsAsInt64() throws {
        let parsed = try #require(Int64(engineVersionStamp()))
        #expect(parsed == SheetMusicEngine.versionStamp)
    }
}
