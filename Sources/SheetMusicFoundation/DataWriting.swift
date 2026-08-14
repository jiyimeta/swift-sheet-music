#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension Data.WritingOptions {
    /// `.atomic` on every platform that has it, and no option at all on
    /// WebAssembly.
    ///
    /// Atomic writing is implemented by writing a temporary file and
    /// renaming it into place. WASI has no temporary-file support, so
    /// swift-foundation marks `.atomic` explicitly unavailable there
    /// rather than silently degrading — which turns a plain
    /// `write(to:options:.atomic)` into a compile error in any target that
    /// has to build for wasm.
    ///
    /// What is given up on wasm is the guarantee, not the write: a crash
    /// partway through leaves a truncated file where other platforms would
    /// leave the previous contents intact.
    public static var atomicIfAvailable: Data.WritingOptions {
        #if os(WASI)
            []
        #else
            .atomic
        #endif
    }
}
