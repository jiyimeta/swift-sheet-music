#if !os(Android) && !os(WASI)
    import Foundation

    /// Opt-in wall-clock accounting for the `OMR_DETECT_EVAL=1` sweep,
    /// enabled with `OMR_DETECT_TIMING=1`.
    ///
    /// It exists because the round that produced the detector recorded
    /// "53 s/page, one Core ML prediction per tile" and named batched
    /// inference as the next round's entry point — a hypothesis that was
    /// never measured against the alternatives. A `coremltools` probe over
    /// the shipped `model.mlpackage` puts one 384² tile at **0.6 ms**, so
    /// all 35 tiles of a page are ~21 ms of the 53 000 ms. Whatever the
    /// sweep spends its time on, the model is not it.
    ///
    /// Rather than replace one unmeasured hypothesis with another, this
    /// splits the per-page cost into named phases and prints them. Phases
    /// nest (`detect` contains `detect.predict`); a nested phase's time is
    /// also counted in its parent, so only compare siblings.
    ///
    /// Disabled it costs one `Bool` read per phase — `measure` is
    /// `@inline(__always)` around a non-escaping closure, so an unmeasured
    /// build pays nothing measurable.
    final class OMRDetectTiming: @unchecked Sendable {
        static let shared = OMRDetectTiming()

        /// Read once at first use rather than per call: `ProcessInfo`'s
        /// environment lookup is a dictionary build on some platforms, and
        /// this sits inside the per-tile loop.
        static let isEnabled: Bool =
            ProcessInfo.processInfo.environment["OMR_DETECT_TIMING"] == "1"

        private let lock = NSLock()
        private var seconds: [String: Double] = [:]
        private var calls: [String: Int] = [:]

        /// Times `body` under `phase` when timing is enabled, and calls it
        /// untouched otherwise.
        @inline(__always)
        func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            guard Self.isEnabled else { return try body() }
            let start = DispatchTime.now().uptimeNanoseconds
            defer {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                lock.lock()
                seconds[phase, default: 0] += elapsed
                calls[phase, default: 0] += 1
                lock.unlock()
            }
            return try body()
        }

        func reset() {
            lock.lock()
            seconds.removeAll()
            calls.removeAll()
            lock.unlock()
        }

        /// One `[detect-timing]` line per phase, slowest first, plus the
        /// per-call mean — the number that makes a phase comparable across
        /// runs with different page counts.
        func report() -> [String] {
            lock.lock()
            let snapshotSeconds = seconds
            let snapshotCalls = calls
            lock.unlock()
            guard !snapshotSeconds.isEmpty else { return [] }
            return snapshotSeconds.sorted { $0.value > $1.value }.map { phase, total in
                let n = snapshotCalls[phase] ?? 0
                let mean = n > 0 ? total / Double(n) : 0
                return String(
                    format: "[detect-timing] %-22@ total=%9.2fs calls=%6d mean=%9.2fms",
                    phase as NSString, total, n, mean * 1000,
                )
            }
        }
    }
#endif
