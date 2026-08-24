@testable import SheetMusicBridgeCore
import SheetMusicFoundation
@testable import SheetMusicWasmBridge
import Testing

/// Runs under `swift package --swift-sdk swift-6.3.3-RELEASE_wasm js test`.
/// Every input is built in memory: a wasm test host has no preopened directory
/// unless one is passed, so a fixture file would make the suite depend on how it
/// was launched.
///
/// The repeating fixture is used wherever the notated and player clocks can
/// disagree. On the four-quarter-note sample they are the same clock, so those
/// assertions would hold for an implementation that ignored the unroll map.
@Suite("playback entry points")
struct PlaybackEntryTests {
    // MARK: Sequences

    @Test("renderMidi returns a Standard MIDI File")
    func renderMidiReturnsSMF() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let bytes = renderMidi(handle: handle)
        #expect(bytes.count > 14)
        // "MThd" — the SMF header chunk.
        #expect(Array(bytes.prefix(4)) == [0x4D, 0x54, 0x68, 0x64])
    }

    @Test("renderMidi for an unknown handle is empty")
    func renderMidiForUnknownHandleIsEmpty() {
        #expect(renderMidi(handle: 999_999).isEmpty)
    }

    @Test("renderMetronomeMidi returns a Standard MIDI File")
    func renderMetronomeMidiReturnsSMF() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(Array(renderMetronomeMidi(handle: handle).prefix(4)) == [0x4D, 0x54, 0x68, 0x64])
    }

    /// A negative position clamps to the top rather than failing, the same way
    /// `PlaybackClock` clamps every other read — a host that subtracts a lead-in
    /// and goes past zero gets the count-in for the start of the score.
    @Test("a negative start clamps to the top of the score")
    func countInSequenceClampsNegativeStart() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let clamped = renderCountInMetronomeMidi(handle: handle, fromPlayerSeconds: -1)
        let atTop = renderCountInMetronomeMidi(handle: handle, fromPlayerSeconds: 0)
        // `.bridgedData`, not the arrays themselves: these are two distinct
        // JavaScript objects, and `JSUint8Array` inherits `JSObject`'s identity
        // equality, which would report them unequal however their bytes compare.
        #expect(clamped.bridgedData == atTop.bridgedData)
    }

    @Test("renderCountInMetronomeMidi for an unknown handle is empty")
    func countInSequenceForUnknownHandleIsEmpty() {
        #expect(renderCountInMetronomeMidi(handle: 999_999, fromPlayerSeconds: 0).isEmpty)
    }

    @Test("countInSeconds is non-negative and finite")
    func countInSecondsIsSane() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let seconds = countInSeconds(handle: handle, fromPlayerSeconds: 0)
        #expect(seconds >= 0)
        #expect(seconds.isFinite)
    }

    /// The reason the count-in takes seconds rather than a measure index: a
    /// start partway through a bar gets a partial lead-in, and that is what a
    /// tap-to-start produces.
    @Test("a count-in starting mid-bar is shorter than one on the downbeat")
    func midBarCountInIsShorter() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        let summary = try #require(playbackSummary(handle: handle))
        let bar = summary.totalPlayerSeconds / Double(summary.measureCount)
        let downbeat = countInSeconds(handle: handle, fromPlayerSeconds: bar)
        let midBar = countInSeconds(handle: handle, fromPlayerSeconds: bar + bar / 2)
        #expect(downbeat > 0)
        #expect(midBar > 0)
        #expect(midBar < downbeat)
    }

    @Test("countInSeconds for an unknown handle is zero")
    func countInSecondsForUnknownHandleIsZero() {
        #expect(countInSeconds(handle: 999_999, fromPlayerSeconds: 0) == 0)
    }

    // MARK: Timeline

    @Test("playbackSummary reports a positive length and a measure count")
    func playbackSummaryIsPopulated() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let summary = try #require(playbackSummary(handle: handle))
        #expect(summary.totalNotatedSeconds > 0)
        #expect(summary.totalPlayerSeconds > 0)
        #expect(summary.measureCount > 0)
        #expect(summary.division > 0)
        #expect(summary.openingQuarterBpm > 0)
    }

    /// The whole reason the summary carries two lengths. On a score without
    /// repeats they coincide, which is why this asserts on the repeating one.
    @Test("the repeat makes the player clock longer than the notated one")
    func repeatLengthensThePlayerClock() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        let summary = try #require(playbackSummary(handle: handle))
        #expect(summary.totalPlayerSeconds > summary.totalNotatedSeconds)
    }

    @Test("playbackSummary for an unknown handle is nil")
    func playbackSummaryForUnknownHandleIsNil() {
        #expect(playbackSummary(handle: 999_999) == nil)
    }

    @Test("metronomeBeats is a flat pair array")
    func metronomeBeatsIsPairs() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let beats = metronomeBeats(handle: handle)
        #expect(!beats.isEmpty)
        #expect(beats.count % 2 == 0)
        // The flag slot is 0 or 1 and nothing else.
        for index in stride(from: 1, to: beats.count, by: 2) {
            #expect(beats[index] == 0 || beats[index] == 1)
        }
    }

    /// Beat positions have to advance monotonically across a repeat's passes. A
    /// beat resolved through a first-occurrence projection would jump backwards
    /// at the repeat boundary and stall a beat indicator for a whole measure.
    @Test("metronome beat positions never run backwards across a repeat")
    func metronomeBeatsAreMonotonic() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        let beats = metronomeBeats(handle: handle)
        #expect(beats.count > 2)
        var previous = -1.0
        for index in stride(from: 0, to: beats.count, by: 2) {
            #expect(beats[index] >= previous)
            previous = beats[index]
        }
    }

    @Test("metronomeBeats for an unknown handle is empty")
    func metronomeBeatsForUnknownHandleIsEmpty() {
        #expect(metronomeBeats(handle: 999_999).isEmpty)
    }

    // MARK: Cursor and seek

    @Test("a cursor rect resolves once a layout has been computed")
    func cursorRectResolvesAfterLayout() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        let rect = try #require(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0))
        #expect(rect.heightMM > 0)
        #expect(rect.measureIndex == 0)
        #expect(rect.notatedSeconds == 0)
    }

    /// The document cache is what turns a cursor into geometry, so a host that
    /// starts playback before laying out gets `nil` rather than a wrong rect.
    @Test("a cursor rect is nil before any layout is computed")
    func cursorRectIsNilWithoutLayout() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0) == nil)
    }

    @Test("measure 0 starts the player at zero")
    func firstMeasureStartsAtZero() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 0) == 0)
    }

    @Test("an out-of-range measure seeks to -1 rather than to the top")
    func outOfRangeMeasureIsSentinel() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 9999) == -1)
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: -1) == -1)
    }

    @Test("a seek target round-trips back to its own measure")
    func seekTargetRoundTrips() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        let seconds = playerSecondsForMeasure(handle: handle, measureIndex: 2)
        #expect(seconds > 0)
        #expect(measureIndexAtPlayerSeconds(handle: handle, playerSeconds: seconds) == 2)
    }

    @Test("measureIndexAtPlayerSeconds for an unknown handle is -1")
    func measureIndexForUnknownHandleIsSentinel() {
        #expect(measureIndexAtPlayerSeconds(handle: 999_999, playerSeconds: 0) == -1)
    }

    // MARK: Tap seek

    @Test("a tap on the first note seeks to the top of the score")
    func tapOnFirstNoteSeeksToTop() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        // Aim at the cursor rectangle the engine itself reports for second 0,
        // rather than at coordinates guessed from the layout.
        let rect = try #require(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0))
        let seconds = playerSecondsAtPoint(
            handle: handle,
            xMM: rect.xMM + rect.widthMM / 2,
            yMM: rect.yMM + rect.heightMM / 2,
        )
        #expect(seconds == 0)
    }

    @Test("a tap seeks somewhere the cursor agrees with")
    func tapRoundTripsThroughTheCursor() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        let rect = try #require(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0))
        // Well to the right of the first note: a later column on the same staff.
        let seconds = playerSecondsAtPoint(
            handle: handle, xMM: rect.xMM + 40, yMM: rect.yMM + rect.heightMM / 2,
        )
        #expect(seconds > 0)
        let landed = try #require(
            cursorRectAtPlayerSeconds(handle: handle, playerSeconds: seconds),
        )
        #expect(landed.xMM > rect.xMM)
    }

    /// Nearest, not hit-test: a tap beside the music snaps to the closest
    /// element rather than being ignored, which is what makes tap-to-seek
    /// usable with a finger. Above and left of everything is the first note.
    @Test("a tap outside the music snaps to the nearest element")
    func tapOutsideSnapsToNearest() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        #expect(playerSecondsAtPoint(handle: handle, xMM: -50, yMM: -50) == 0)
    }

    @Test("a tap before any layout hits nothing")
    func tapWithoutLayoutIsSentinel() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(playerSecondsAtPoint(handle: handle, xMM: 30, yMM: 40) == -1)
    }

    // MARK: Loop

    @Test("loopPlayerSeconds returns an ordered pair")
    func loopPlayerSecondsIsOrderedPair() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        let summary = try #require(playbackSummary(handle: handle))
        let pair = loopPlayerSeconds(
            handle: handle, fromMeasureIndex: 0, toMeasureExclusive: summary.measureCount,
        )
        #expect(pair.count == 2)
        #expect(pair[0] < pair[1])
    }

    @Test("an inverted or empty loop range yields nothing")
    func invertedLoopRangeIsEmpty() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        #expect(loopPlayerSeconds(handle: handle, fromMeasureIndex: 2, toMeasureExclusive: 1).isEmpty)
        #expect(loopPlayerSeconds(handle: handle, fromMeasureIndex: 1, toMeasureExclusive: 1).isEmpty)
        #expect(loopHighlightRects(handle: handle, fromMeasureIndex: 2, toMeasureExclusive: 1).isEmpty)
    }

    @Test("loopHighlightRects is a flat quad array once a layout exists")
    func loopHighlightRectsIsQuads() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        let summary = try #require(playbackSummary(handle: handle))
        let rects = loopHighlightRects(
            handle: handle, fromMeasureIndex: 0, toMeasureExclusive: summary.measureCount,
        )
        #expect(!rects.isEmpty)
        #expect(rects.count % 4 == 0)
    }

    @Test("loopHighlightRects is empty before any layout is computed")
    func loopHighlightRectsNeedsLayout() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.repeatingMscz()))
        defer { releaseScore(handle: handle) }
        #expect(loopHighlightRects(handle: handle, fromMeasureIndex: 0, toMeasureExclusive: 3).isEmpty)
    }

    // MARK: Lifetime

    /// `releaseScore` has to drop the playback clock along with the score and
    /// the layout. A handle is never reused inside a page, so the symptom of a
    /// missing release is a leak rather than a wrong answer — which is exactly
    /// why nothing else would catch it.
    @Test("everything answers empty after the handle is released")
    func releasedHandleAnswersEmpty() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        releaseScore(handle: handle)
        #expect(renderMidi(handle: handle).isEmpty)
        #expect(playbackSummary(handle: handle) == nil)
        #expect(metronomeBeats(handle: handle).isEmpty)
        #expect(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0) == nil)
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 0) == -1)
    }
}
