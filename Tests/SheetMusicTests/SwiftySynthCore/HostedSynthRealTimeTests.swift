#if canImport(SheetMusicAudioSwiftySynthCore) && canImport(Darwin)
    import Darwin
    import Foundation
    import SheetMusicAudioSwiftySynthCore
    import SwiftySynth
    import Testing

    /// The audio writer thread renders through `HostedSynth` every block; after warm-up that allocates nothing — the
    /// lock, the playing sequence, the choke hook and the effects bus included.
    ///
    /// Measured the way swiftysynth's own `RealTimeSafetyTests` measure: the process-global malloc zone before and
    /// after a window of renders. Suites running beside this one land heap work in some windows, never in all of them,
    /// while an allocation on the render path shows up in every window — so the test passes on the first window that
    /// nets zero or less and fails only when every window allocated.
    struct HostedSynthRealTimeTests {
        @Test func `rendering a playing sequence allocates nothing after warm-up`() throws {
            let synth = try #require(HostedSynth(sampleRate: 48000, voicing: .score))
            #expect(try synth.loadSoundFont(HostedSynthFixtures.clickFont(seconds: 0.2)))
            synth.programSelect(channel: 9, bank: 128, program: 0)
            synth.controlChange(channel: 9, controller: 7, value: 110)
            let smf = try HostedSynthFixtures.smf(
                notes: (0 ..< 4000).map {
                    (tick: $0 * 60, channel: 9, key: $0 % 2 == 0 ? 76 : 77, length: 50)
                },
            )
            let sequence = try #require(synth.attachSequence(smf: smf))
            sequence.play()

            let left = UnsafeMutablePointer<Float>.allocate(capacity: 480)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: 480)
            defer {
                left.deallocate()
                right.deallocate()
            }
            func renderBlocks(_ count: Int) {
                for _ in 0 ..< count {
                    synth.withLock { synth.renderHoldingLock(left: left, right: right, frames: 480) }
                }
            }
            renderBlocks(400)

            func measureWindow() -> (blocks: Int, size: Int) {
                var before = malloc_statistics_t()
                malloc_zone_statistics(malloc_default_zone(), &before)
                renderBlocks(200)
                var after = malloc_statistics_t()
                malloc_zone_statistics(malloc_default_zone(), &after)
                return (
                    Int(after.blocks_in_use) - Int(before.blocks_in_use),
                    Int(after.size_in_use) - Int(before.size_in_use),
                )
            }
            var windows: [(blocks: Int, size: Int)] = []
            for _ in 0 ..< 8 {
                let delta = measureWindow()
                windows.append(delta)
                if delta.blocks <= 0, delta.size <= 0 { break }
                renderBlocks(50)
            }
            #expect(windows.contains { $0.blocks <= 0 && $0.size <= 0 }, "every window allocated: \(windows)")
            #expect(sequence.currentTick > 0)
        }
    }
#endif
