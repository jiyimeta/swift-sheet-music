@testable import SheetMusicWasmBridge
import Testing

@Suite("tick introspection entry points")
struct TickIntrospectionEntryTests {
    @Test("a note reports pitch and flattened staff index")
    func noteReportsPitchAndStaff() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        #expect(pitchAndStaffOfNote(
            handle: handle,
            partIndex: 0,
            staffIndexInPart: 0,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 1,
        ) == [64, 0])
    }

    @Test("an unresolved note has no pitch or staff")
    func unresolvedNoteHasNoPitchOrStaff() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        #expect(pitchAndStaffOfNote(
            handle: handle,
            partIndex: 0,
            staffIndexInPart: 0,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 99,
            noteIndexInChord: 0,
        ).isEmpty)
        #expect(pitchAndStaffOfNote(
            handle: 999_999,
            partIndex: 0,
            staffIndexInPart: 0,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        ).isEmpty)
    }

    @Test("note and rest end ticks are notated ticks")
    func itemEndTicksResolve() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        #expect(itemEndTick(
            handle: handle, kind: 0, partIndex: 0, staffIndexInPart: 0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        ) == 480)
        #expect(itemEndTick(
            handle: handle, kind: 1, partIndex: 0, staffIndexInPart: 0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: -1,
        ) == 960)
    }

    @Test("item end tick uses -1 for unsupported or unresolved input")
    func itemEndTickUsesSentinel() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        #expect(itemEndTick(
            handle: 999_999, kind: 0, partIndex: 0, staffIndexInPart: 0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        ) == -1)
        #expect(itemEndTick(
            handle: handle, kind: 2, partIndex: 0, staffIndexInPart: 0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: -1,
        ) == -1)
        #expect(itemEndTick(
            handle: handle, kind: 0, partIndex: 0, staffIndexInPart: 0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 99, noteIndexInChord: 0,
        ) == -1)
    }

    @Test("earliestOf returns the earliest resolvable item")
    func earliestOfReturnsEarliestItem() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        let lateNote = [0.0, 0, 0, 0, 0, 2, 0]
        let unresolvedNote = [0.0, 0, 0, 0, 0, 99, 0]
        let earlyRest = [1.0, 0, 0, 0, 0, 1, -1]
        #expect(earliestOf(
            handle: handle,
            itemScalars: lateNote + unresolvedNote + earlyRest,
        ) == earlyRest)
    }

    @Test("earliestOf preserves input order for tied noteheads")
    func earliestOfPreservesInputOrderForTies() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        let secondNotehead = [0.0, 0, 0, 0, 0, 0, 1]
        let firstNotehead = [0.0, 0, 0, 0, 0, 0, 0]
        #expect(earliestOf(
            handle: handle,
            itemScalars: secondNotehead + firstNotehead,
        ) == secondNotehead)
    }

    @Test("earliestOf rejects malformed scalar records")
    func earliestOfRejectsMalformedRecords() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.tickIntrospectionScore())))
        defer { releaseScore(handle: handle) }
        #expect(earliestOf(handle: 999_999, itemScalars: [0, 0, 0, 0, 0, 0, 0]).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: []).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: [0, 0]).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: [0.5, 0, 0, 0, 0, 0, 0]).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: [0, 0, 0, 0, 0, .infinity, 0]).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: [2, 0, 0, 0, 0, 0, -1]).isEmpty)
        #expect(earliestOf(handle: handle, itemScalars: [0, 0, 0, 0, 0, 99, 0]).isEmpty)
    }
}
