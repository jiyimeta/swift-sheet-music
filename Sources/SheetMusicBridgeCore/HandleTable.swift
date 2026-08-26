import SheetMusicFoundation

/// Maps opaque `Int64` handles to retained Swift objects. Thread-safe via
/// `SerialLock`. Handle `0` is reserved to mean "invalid / not
/// found" — JNI callers use it as the failure sentinel for `nativeLoadScore`.
public final class HandleTable<Value>: @unchecked Sendable {
    private let lock = SerialLock(label: "SheetMusicBridgeCore.HandleTable")
    private var nextHandle: Int64 = 1
    private var storage: [Int64: Value] = [:]

    public init() {}

    public func insert(_ value: Value) -> Int64 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            storage[h] = value
            return h
        }
    }

    public func value(for handle: Int64) -> Value? {
        lock.withLock { storage[handle] }
    }

    public func release(_ handle: Int64) {
        lock.withLock { _ = storage.removeValue(forKey: handle) }
    }

    /// Swaps the value behind an existing handle. A no-op that returns `false` for an unknown handle — e.g. one
    /// released concurrently with the call that produced `value` — so a caller that only checked "does this handle
    /// exist" earlier still finds out the write didn't land.
    @discardableResult
    public func replace(_ handle: Int64, with value: Value) -> Bool {
        lock.withLock {
            guard storage[handle] != nil else { return false }
            storage[handle] = value
            return true
        }
    }
}
