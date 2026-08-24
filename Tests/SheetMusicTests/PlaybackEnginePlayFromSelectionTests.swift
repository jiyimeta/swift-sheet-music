#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudio
        @testable import SheetMusicAudioApple
        import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        @testable import SheetMusicCore
        import SheetMusicMIDI
        import Testing

        /// Diagnostic: pressing play with a note SELECTED did nothing in the macOS example app,
        /// while re-selecting a note mid-playback worked. Drives the real `SwiftySynthBackend`
        /// through `PlaybackEngine.play(from:)` — the exact path the example's spacebar takes —
        /// to find out whether the new `isAtEnd` end-stop is firing spuriously right after the
        /// seek that a selection triggers.
        extension AudioEngineSerial {
            @MainActor
            struct PlaybackEnginePlayFromSelectionTests {
                private struct FixedResolver: SoundfontResolver {
                    let url: URL
                    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                        url
                    }

                    var defaultGMSoundfontURL: URL? {
                        url
                    }
                }

                private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                    for _ in 0 ..< 250 {
                        if backend.isReady { return }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    Issue.record("SwiftySynthBackend never became ready")
                }

                /// Four measures of four quarters each, so there is a genuinely "mid-score" note
                /// to start from (measure 2, beat 1).
                private func makeScore() -> Score {
                    let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                    let measures = (0 ..< 4).map { index in
                        var elements: [VoiceElement] = []
                        if index == 0 {
                            elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                        }
                        elements.append(contentsOf: [
                            .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                        ])
                        return Measure(voices: [Voice(elements: elements)])
                    }
                    let part = Part(
                        id: "p",
                        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                        staves: [Staff(measures: measures)],
                    )
                    return Score(division: 480, parts: [part])
                }

                /// Measure 2's first chord. Measures 1-3 have no leading time signature, so the
                /// chord sits at element index 0.
                private var midScoreNoteID: NoteID {
                    NoteID(
                        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                        measureIndex: 2, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
                    )
                }

                @Test(
                    "play from a selected mid-score note keeps playing (does not self-stop on the first poll)",
                    .enabled(if: FileManager.default.fileExists(atPath: swiftySynthSoundfontPath)),
                )
                func playFromSelectedNoteKeepsPlaying() async throws {
                    let backend = SwiftySynthBackend(sampleRate: 44100)
                    let engine = PlaybackEngine(
                        soundfontResolver: FixedResolver(
                            url: URL(fileURLWithPath: swiftySynthSoundfontPath),
                        ),
                        backend: backend,
                    )
                    let score = makeScore()
                    try engine.prepare(score: score)
                    try await awaitReady(backend)

                    // Exactly what the example app's spacebar does with a selection.
                    engine.play(from: .item(.note(midScoreNoteID)), in: score)
                    #expect(engine.state == .playing)

                    // Is the transport genuinely mid-sequence after the selection's seek, or does
                    // it read as finished?
                    #expect(backend.isAtEnd == false)

                    // The first 30 Hz poll must not stop it.
                    engine.tickCursor()
                    #expect(engine.state == .playing)
                }

                /// Same, from the top — isolates whether a selection is required to trigger it.
                @Test(
                    "play from the start keeps playing",
                    .enabled(if: FileManager.default.fileExists(atPath: swiftySynthSoundfontPath)),
                )
                func playFromStartKeepsPlaying() async throws {
                    let backend = SwiftySynthBackend(sampleRate: 44100)
                    let engine = PlaybackEngine(
                        soundfontResolver: FixedResolver(
                            url: URL(fileURLWithPath: swiftySynthSoundfontPath),
                        ),
                        backend: backend,
                    )
                    let score = makeScore()
                    try engine.prepare(score: score)
                    try await awaitReady(backend)

                    engine.play(in: score)
                    #expect(engine.state == .playing)
                    #expect(backend.isAtEnd == false)
                    engine.tickCursor()
                    #expect(engine.state == .playing)
                }
            }
        }
    #endif
#endif
