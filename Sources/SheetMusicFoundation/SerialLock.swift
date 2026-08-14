// Mutual exclusion for the portable targets.
//
// `Foundation` re-exports Dispatch, so code that said `import Foundation` also got
// `DispatchQueue` — the same way it got `cos` and `pow` from the platform C library.
// `FoundationEssentials` re-exports neither, so this file supplies the first for the
// same reason `SheetMusicFoundation.swift` supplies the second.
//
// Apple and Android import Dispatch as a module in its own right and get real
// serialization. WASI has no Dispatch at all.

#if canImport(Dispatch)
    import Dispatch
#elseif os(WASI)
#else
    #error("SerialLock has no backing on this platform — add one before building here.")
#endif

/// Serializes access to state shared across threads.
///
/// **The closure is deliberately non-`async`, and must stay that way.** That signature is
/// what makes the WASI implementation below correct rather than merely convenient, and the
/// reasoning is spelled out there. On Dispatch, `queue.sync` cannot take an `async` closure
/// anyway, so adding an `async` variant would break only the platform where nothing stops you.
///
/// When this package's deployment floor reaches iOS 18 / macOS 15, the whole type collapses
/// into `Synchronization.Mutex`, which exists on Apple, Android and in the wasm SDK alike —
/// including the WASI special case below. That swap is a one-file change precisely because
/// callers only ever see `withLock`. Doing it early would mean raising the floor for everyone
/// to solve a problem this file already solves.
package final class SerialLock: @unchecked Sendable {
    #if canImport(Dispatch)
        private let queue: DispatchQueue

        package init(label: String) {
            queue = DispatchQueue(label: label)
        }

        package func withLock<T>(_ body: () throws -> T) rethrows -> T {
            try queue.sync(execute: body)
        }

    #elseif os(WASI)
        /// wasip1 is single-threaded — no pthreads, and Swift Concurrency runs on a
        /// cooperative single-threaded executor where interleaving happens only at
        /// suspension points. A *synchronous* closure contains none, so nothing can run
        /// between this flag going up and coming down. That is the whole correctness
        /// argument, and it rests entirely on `withLock` being non-`async`.
        ///
        /// The flag is not vestigial: a bare no-op would diverge from Dispatch on
        /// reentrancy, where `queue.sync` deadlocks and doing nothing quietly succeeds.
        /// Code that reenters would then pass here and hang on device. Checking makes wasm
        /// stricter than Dispatch rather than looser, and it also catches a hazard specific
        /// to this platform — a critical section calling into JS that synchronously calls
        /// back in.
        ///
        /// `wasip1-threads` would break the argument above, and no `#if` distinguishes it
        /// from `wasip1` (both are `os(WASI)`). The guard therefore lives where such a
        /// build would have to be requested: `Scripts/wasm-size.sh` rejects a `-threads`
        /// triple and points here.
        private var isLocked = false

        package init(label _: String) {}

        package func withLock<T>(_ body: () throws -> T) rethrows -> T {
            precondition(
                !isLocked,
                "SerialLock reentered. On Dispatch platforms this is a deadlock, so the "
                    + "call path is wrong everywhere, not only here.",
            )
            isLocked = true
            defer { isLocked = false }
            return try body()
        }
    #endif
}
