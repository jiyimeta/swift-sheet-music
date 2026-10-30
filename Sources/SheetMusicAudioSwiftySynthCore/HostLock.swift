#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif os(WASI)
#else
    #error("HostLock has no backing on this platform — add one before building here.")
#endif

/// A plain mutex around one `HostedSynth`'s state, taken by the audio render thread every block and by control calls.
///
/// A pthread mutex rather than `Synchronization.Mutex`: this target also builds for the Apple host, whose deployment
/// floor (macOS 14 / iOS 17) predates `Mutex`, and annotating the host objects for availability would spread through
/// the JNI bridge's globals. On Android `Mutex` is the same futex-backed primitive underneath. Heap-allocated because a
/// pthread mutex must not move once initialized.
final class HostLock: @unchecked Sendable {
    #if os(WASI)
        /// wasip1 has no threads (wasi-libc declares no pthread mutex without `-threads`), so nothing can run between
        /// this flag going up and coming down while `withLock`'s body is synchronous — the same argument
        /// `SerialLock` makes for its WASI branch. Nothing in the WebAssembly product links this target today; the
        /// branch keeps it compiling there rather than failing at `pthread_mutex_t`. Reentering traps, as a pthread
        /// mutex would deadlock.
        private var isLocked = false

        init() {}

        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            precondition(!isLocked, "HostLock reentered; on a threaded platform this deadlocks.")
            isLocked = true
            defer { isLocked = false }
            return try body()
        }

    #else
        private let mutex: UnsafeMutablePointer<pthread_mutex_t>

        init() {
            mutex = .allocate(capacity: 1)
            mutex.initialize(to: pthread_mutex_t())
            pthread_mutex_init(mutex, nil)
        }

        deinit {
            pthread_mutex_destroy(mutex)
            mutex.deinitialize(count: 1)
            mutex.deallocate()
        }

        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            pthread_mutex_lock(mutex)
            defer { pthread_mutex_unlock(mutex) }
            return try body()
        }
    #endif
}
