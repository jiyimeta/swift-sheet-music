#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// Where a seek lands while an A–B loop is set. Stopped or paused, the cursor goes where it was sent — the user is
    /// parking it, typically to set a new B past the section — and the loop takes over when playback starts. Playing,
    /// a seek outside the loop snaps to its start, so playback never leaves the section.
    ///
    /// The first half is a user report (2026-11-02): with a section looping, a tap past it to extend the section sent
    /// the cursor back to the section's start, so B could not be set there; only a second tap stuck, because the
    /// engine's cursor no longer changed and nothing told the reader to move it.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine seek outside the loop")
        @MainActor
        struct PlaybackEngineSeekOutsideLoopTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            /// One 4/4 bar of quarters at division 480: onsets 0 / 480 / 960 / 1440 on elements 1...4.
            private func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let voice = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )
                return Score(division: 480, parts: [part])
            }

            private func note(_ elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0, voiceIndex: 0, elementIndex: elementIndex, noteIndexInChord: 0,
                )
            }

            /// An engine on a recording backend with the first two quarters looping (ticks 0 ..< 960).
            private func setUp() throws -> (RecordingBackend, PlaybackEngine, Score) {
                let backend = RecordingBackend()
                let score = makeScore()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                engine.setLoop(from: .item(.note(note(1))), throughEndOf: .note(note(2)))
                return (backend, engine, score)
            }

            @Test("a stopped seek past the loop leaves the cursor where it was sent")
            func stoppedSeekStays() throws {
                let (backend, engine, _) = try setUp()
                engine.seek(to: .item(.note(note(4))))
                #expect(engine.currentCursor == .item(.note(note(4))))
                #expect(backend.seekCalls.last == 1440)
            }

            @Test("a paused seek past the loop leaves the cursor where it was sent")
            func pausedSeekStays() throws {
                let (backend, engine, score) = try setUp()
                engine.play(in: score)
                engine.pause()
                engine.seek(to: .item(.note(note(3))))
                #expect(engine.currentCursor == .item(.note(note(3))))
                #expect(backend.seekCalls.last == 960)
            }

            @Test("playing from a cursor parked past the loop starts at the loop's start")
            func playFromParkedCursorStartsAtTheLoop() throws {
                let (backend, engine, score) = try setUp()
                engine.seek(to: .item(.note(note(4))))
                engine.play(in: score)
                #expect(backend.seekCalls.last == 0)
                #expect(engine.currentCursor == .item(.note(note(1))))
            }

            @Test("a seek past the loop while playing snaps to the loop's start")
            func playingSeekSnaps() throws {
                let (backend, engine, score) = try setUp()
                engine.play(in: score)
                engine.seek(to: .item(.note(note(4))))
                #expect(backend.seekCalls.last == 0)
                #expect(engine.currentCursor == .item(.note(note(1))))
            }
        }
    }
#endif
