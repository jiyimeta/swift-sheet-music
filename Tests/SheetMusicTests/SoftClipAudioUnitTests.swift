#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    import Testing

    /// The soft-clip curve wired into a real `AVAudioEngine` graph. The
    /// curve itself is covered by `SoftClipTests`; what matters here is
    /// that the node is registered, instantiable, and actually processes
    /// the audio flowing through it.
    extension AudioEngineSerial {
        @Suite("Soft clip audio unit")
        struct SoftClipAudioUnitTests {
            /// A bare chain passes overshoot straight through — measured:
            /// float32 connections do not clamp. That is the baseline the
            /// node has to change.
            @Test("a chain without the node passes overshoot through")
            func bareChainDoesNotClamp() throws {
                let peak = try renderSine(amplitude: 2.0, softClipped: false)
                #expect(peak > 1.9)
            }

            @Test("the node keeps the mix inside full scale")
            func nodeShapesTheMix() throws {
                let peak = try renderSine(amplitude: 2.0, softClipped: true)
                #expect(peak <= 1.0)
                #expect(peak > 0.9)
            }

            /// Below the knee the node has to be inaudible, not merely
            /// quiet — a master stage that colors ordinary playback would
            /// be worse than no master stage.
            @Test("the node leaves quiet material untouched")
            func quietMaterialIsUntouched() throws {
                let bare = try renderSine(amplitude: 0.5, softClipped: false)
                let shaped = try renderSine(amplitude: 0.5, softClipped: true)
                #expect(shaped == bare)
            }

            /// Switching the master output stage flips `bypass` rather
            /// than rewiring a running graph, so bypass has to actually
            /// take the curve out of the signal path.
            @Test("bypassing the node restores the unshaped signal")
            func bypassRestoresTheSignal() throws {
                let peak = try renderSine(
                    amplitude: 2.0, softClipped: true, bypassed: true,
                )
                #expect(peak > 1.9)
            }
        }
    }

    /// Render a 440 Hz sine at `amplitude` through a two-mixer chain,
    /// optionally with the soft-clip node in the path, and return the
    /// peak of the settled output.
    private nonisolated func renderSine(
        amplitude: Float, softClipped: Bool, bypassed: Bool = false,
    ) throws -> Float {
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
        )
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        phase.initialize(to: 0)
        defer { phase.deallocate() }
        let step = 2 * Double.pi * 440 / 44100
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            for frame in 0 ..< Int(frameCount) {
                let value = amplitude * Float(sin(phase.pointee))
                phase.pointee += step
                for buffer in abl {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        let mixer = AVAudioMixerNode()
        engine.attach(source)
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: format)
        if softClipped {
            let node = SoftClipAudioUnit.makeNode()
            node.bypass = bypassed
            engine.attach(node)
            engine.connect(mixer, to: node, format: format)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
        }

        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 4096,
        )
        try engine.start()
        defer { engine.stop() }
        let out = try #require(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
        ))
        var peak: Float = 0
        for block in 0 ..< 8 {
            _ = try engine.renderOffline(4096, to: out)
            guard block >= 4 else { continue } // let the graph settle
            peak = max(peak, PlaybackEngine.level(in: out).peak)
        }
        return peak
    }
#endif
