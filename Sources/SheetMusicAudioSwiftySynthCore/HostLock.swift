#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A plain mutex around one `HostedSynth`'s state, taken by the audio render thread every block and by control calls.
///
/// A pthread mutex rather than `Synchronization.Mutex`: this target also builds for the Apple host, whose deployment
/// floor (macOS 14 / iOS 17) predates `Mutex`, and annotating the host objects for availability would spread through
/// the JNI bridge's globals. On Android `Mutex` is the same futex-backed primitive underneath. Heap-allocated because a
/// pthread mutex must not move once initialized.
final class HostLock: @unchecked Sendable {
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
}
