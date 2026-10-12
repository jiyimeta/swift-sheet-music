#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    /// The Android engine's `replaceScore` carries its cursor and loop from the score it prepared to the edited one
    /// through these three entry points: a snapshot of the score before the edit, and the cursor and the loop found
    /// again at the same measure and offset (`PlaybackMeasurePosition`).
    @Suite("transport carry bridge")
    struct TransportCarryBridgeTests {
        /// `measureCount` 4/4 measures of quarter notes at 480 ppq, so measure `m` starts at `m × 1920`.
        private static func score(measureCount: Int) -> Score {
            let measures = (0 ..< measureCount).map { index in
                let timeSignature: [VoiceElement] = index == 0
                    ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    : []
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                return Measure(voices: [Voice(elements: timeSignature + Array(repeating: .chord(quarter), count: 4))])
            }
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
            )
        }

        private static func cursor(atTick tick: Int, in score: Score) throws -> ScoreCursor {
            try #require(PlaybackTimeline(score: score).frame(atTick: tick)?.cursor)
        }

        private static func tick(of cursorBytes: Data, in score: Score) throws -> Int? {
            let cursor = try ScoreCursorCodec.decode(cursorBytes)
            return PlaybackTimeline(score: score).frame(forCursor: cursor)?.tick
        }

        @Test("a snapshot is a second handle that keeps the score as it stood")
        func snapshotKeepsTheScoreAsItStood() {
            let handle = scoreTable.insert(Self.score(measureCount: 3))
            defer { nativeReleaseScore(handle: handle) }

            let snapshot = nativeSnapshotScore(scoreHandle: handle)
            defer { nativeReleaseScore(handle: snapshot) }
            scoreTable.replace(handle, with: Self.score(measureCount: 1))

            #expect(snapshot != 0)
            #expect(snapshot != handle)
            #expect(scoreTable.value(for: snapshot) == Self.score(measureCount: 3))
        }

        @Test("an unknown handle has no snapshot")
        func unknownHandleHasNoSnapshot() {
            #expect(nativeSnapshotScore(scoreHandle: -42) == 0)
        }

        @Test("the cursor comes back at the same measure and offset in the edited score")
        func cursorKeepsItsMeasureAndOffset() throws {
            let before = Self.score(measureCount: 3)
            let after = Self.score(measureCount: 4)
            let from = scoreTable.insert(before)
            let to = scoreTable.insert(after)
            defer {
                nativeReleaseScore(handle: from)
                nativeReleaseScore(handle: to)
            }
            let cursor = try Self.cursor(atTick: 2400, in: before)

            let carried = nativeCarryCursor(
                fromScoreHandle: from, toScoreHandle: to, cursorBytes: ScoreCursorCodec.encode(cursor),
            )

            #expect(try Self.tick(of: carried, in: after) == 2400)
        }

        @Test("a cursor in a measure the edit removed lands on the start of the last measure")
        func cursorInARemovedMeasureLandsOnTheLast() throws {
            let before = Self.score(measureCount: 3)
            let after = Self.score(measureCount: 2)
            let from = scoreTable.insert(before)
            let to = scoreTable.insert(after)
            defer {
                nativeReleaseScore(handle: from)
                nativeReleaseScore(handle: to)
            }
            let cursor = try Self.cursor(atTick: 4320, in: before)

            let carried = nativeCarryCursor(
                fromScoreHandle: from, toScoreHandle: to, cursorBytes: ScoreCursorCodec.encode(cursor),
            )

            #expect(try Self.tick(of: carried, in: after) == 1920)
        }

        @Test("a cursor that cannot be carried answers empty bytes")
        func uncarriableCursorIsEmpty() throws {
            let score = Self.score(measureCount: 2)
            let handle = scoreTable.insert(score)
            defer { nativeReleaseScore(handle: handle) }
            let cursorBytes = try ScoreCursorCodec.encode(Self.cursor(atTick: 0, in: score))

            #expect(nativeCarryCursor(fromScoreHandle: -42, toScoreHandle: handle, cursorBytes: cursorBytes).isEmpty)
            #expect(nativeCarryCursor(fromScoreHandle: handle, toScoreHandle: -42, cursorBytes: cursorBytes).isEmpty)
            #expect(nativeCarryCursor(fromScoreHandle: handle, toScoreHandle: handle, cursorBytes: Data()).isEmpty)
        }

        @Test("the loop keeps its measures and offsets")
        func loopKeepsItsMeasuresAndOffsets() {
            let from = scoreTable.insert(Self.score(measureCount: 3))
            let to = scoreTable.insert(Self.score(measureCount: 4))
            defer {
                nativeReleaseScore(handle: from)
                nativeReleaseScore(handle: to)
            }

            let carried = nativeCarryLoop(fromScoreHandle: from, toScoreHandle: to, startTick: 2400, endTick: 4320)

            #expect(carried == [2400, 4320])
        }

        @Test("a loop the edit left spanning nothing is none")
        func loopSpanningNothingIsEmpty() {
            let from = scoreTable.insert(Self.score(measureCount: 4))
            let to = scoreTable.insert(Self.score(measureCount: 2))
            defer {
                nativeReleaseScore(handle: from)
                nativeReleaseScore(handle: to)
            }

            // Measures 2 and 3 are gone, so both ends clamp onto the start of the last measure.
            let carried = nativeCarryLoop(fromScoreHandle: from, toScoreHandle: to, startTick: 3840, endTick: 5760)

            #expect(carried.isEmpty)
        }

        @Test("an empty or reversed loop is none")
        func emptyLoopIsEmpty() {
            let handle = scoreTable.insert(Self.score(measureCount: 2))
            defer { nativeReleaseScore(handle: handle) }

            #expect(nativeCarryLoop(fromScoreHandle: handle, toScoreHandle: handle, startTick: 960, endTick: 960)
                .isEmpty)
            #expect(nativeCarryLoop(fromScoreHandle: handle, toScoreHandle: handle, startTick: 960, endTick: 0)
                .isEmpty)
        }
    }
#endif
