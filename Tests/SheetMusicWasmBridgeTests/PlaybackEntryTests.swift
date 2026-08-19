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
        let handle = try loadScore(bytes: SampleScore.mscz())
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
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(Array(renderMetronomeMidi(handle: handle).prefix(4)) == [0x4D, 0x54, 0x68, 0x64])
    }

    @Test("renderCountInMetronomeMidi for an out-of-range measure is empty")
    func countInSequenceOutOfRangeIsEmpty() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(renderCountInMetronomeMidi(handle: handle, fromMeasureIndex: 9999).isEmpty)
    }

    @Test("countInSeconds is non-negative and finite")
    func countInSecondsIsSane() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        let seconds = countInSeconds(handle: handle, fromMeasureIndex: 0)
        #expect(seconds >= 0)
        #expect(seconds.isFinite)
    }

    @Test("countInSeconds for an unknown handle is zero")
    func countInSecondsForUnknownHandleIsZero() {
        #expect(countInSeconds(handle: 999_999, fromMeasureIndex: 0) == 0)
    }

    // MARK: Timeline

    @Test("playbackSummary reports a positive length and a measure count")
    func playbackSummaryIsPopulated() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
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
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
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
        let handle = try loadScore(bytes: SampleScore.mscz())
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
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
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
        let handle = try loadScore(bytes: SampleScore.mscz())
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
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0) == nil)
    }

    @Test("measure 0 starts the player at zero")
    func firstMeasureStartsAtZero() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 0) == 0)
    }

    @Test("an out-of-range measure seeks to -1 rather than to the top")
    func outOfRangeMeasureIsSentinel() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 9999) == -1)
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: -1) == -1)
    }

    @Test("a seek target round-trips back to its own measure")
    func seekTargetRoundTrips() throws {
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
        defer { releaseScore(handle: handle) }
        let seconds = playerSecondsForMeasure(handle: handle, measureIndex: 2)
        #expect(seconds > 0)
        #expect(measureIndexAtPlayerSeconds(handle: handle, playerSeconds: seconds) == 2)
    }

    @Test("measureIndexAtPlayerSeconds for an unknown handle is -1")
    func measureIndexForUnknownHandleIsSentinel() {
        #expect(measureIndexAtPlayerSeconds(handle: 999_999, playerSeconds: 0) == -1)
    }

    // MARK: Loop

    @Test("loopPlayerSeconds returns an ordered pair")
    func loopPlayerSecondsIsOrderedPair() throws {
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
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
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        #expect(loopPlayerSeconds(handle: handle, fromMeasureIndex: 2, toMeasureExclusive: 1).isEmpty)
        #expect(loopPlayerSeconds(handle: handle, fromMeasureIndex: 1, toMeasureExclusive: 1).isEmpty)
        #expect(loopHighlightRects(handle: handle, fromMeasureIndex: 2, toMeasureExclusive: 1).isEmpty)
    }

    @Test("loopHighlightRects is a flat quad array once a layout exists")
    func loopHighlightRectsIsQuads() throws {
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
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
        let handle = try loadScore(bytes: SampleScore.repeatingMscz())
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
        let handle = try loadScore(bytes: SampleScore.mscz())
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        releaseScore(handle: handle)
        #expect(renderMidi(handle: handle).isEmpty)
        #expect(playbackSummary(handle: handle) == nil)
        #expect(metronomeBeats(handle: handle).isEmpty)
        #expect(cursorRectAtPlayerSeconds(handle: handle, playerSeconds: 0) == nil)
        #expect(playerSecondsForMeasure(handle: handle, measureIndex: 0) == -1)
    }
}
