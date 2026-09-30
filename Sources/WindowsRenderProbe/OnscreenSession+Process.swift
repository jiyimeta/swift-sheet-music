import Foundation
import WinSDK

/// What the session reads from the process itself: CPU time, private bytes, and durations in milliseconds.
extension OnscreenSession {
    /// The process's CPU time in seconds, from the cycles its threads ran (`QueryProcessCycleTime`), or why it could
    /// not be read; a failure is its own result, never a zero that would read as an idle process.
    ///
    /// Not `GetProcessTimes`: that charges whichever thread runs when the clock ticks (every 15.6 ms), and a frame loop
    /// paced by the display wakes, draws for a fraction of a millisecond and sleeps between ticks — over a 60 s cursor
    /// run of 2,970 frames it was charged nothing at all. Cycles are counted at every context switch.
    static func processCPUSeconds() -> Result<Double, ProbeError> {
        var cycles: UInt64 = 0
        guard QueryProcessCycleTime(GetCurrentProcess(), &cycles) else {
            return .failure(ProbeError("QueryProcessCycleTime failed: \(GetLastError())"))
        }
        guard let rate = cyclesPerSecond else {
            return .failure(ProbeError("QueryThreadCycleTime failed while calibrating"))
        }
        return .success(Double(cycles) / rate)
    }

    /// How many cycles a thread accrues per second while it runs: this thread's cycle time over a 100 ms busy spin.
    /// A preemption during the spin only lowers it, which overstates the CPU share — the side a budget gate can take.
    static let cyclesPerSecond: Double? = {
        let clock = ContinuousClock()
        var from: UInt64 = 0
        var to: UInt64 = 0
        guard QueryThreadCycleTime(GetCurrentThread(), &from) else { return nil }
        let start = clock.now
        while clock.now - start < .milliseconds(100) {}
        let elapsed = clock.now - start
        guard QueryThreadCycleTime(GetCurrentThread(), &to), to > from else { return nil }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Double(to - from) / seconds
    }()

    static func privateBytes() -> Int {
        var counters = PROCESS_MEMORY_COUNTERS_EX()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
        let size = counters.cb
        let read = withUnsafeMutablePointer(to: &counters) { pointer in
            pointer.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) {
                K32GetProcessMemoryInfo(GetCurrentProcess(), $0, size)
            }
        }
        return read ? Int(counters.PrivateUsage) : 0
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
