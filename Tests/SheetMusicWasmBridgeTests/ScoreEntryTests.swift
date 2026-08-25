import SheetMusicCore
@testable import SheetMusicWasmBridge
import Testing

@Suite("score lifecycle")
struct ScoreEntryTests {
    @Test("an empty payload yields the invalid handle")
    func emptyPayloadIsInvalid() {
        #expect(loadScore(bytes: jsBytes([])) == 0)
    }

    @Test("garbage yields the invalid handle")
    func garbageIsInvalid() {
        #expect(loadScore(bytes: jsBytes([0x00, 0x01, 0x02, 0x03])) == 0)
    }

    @Test("a valid mscz yields a live handle")
    func validPayloadLoads() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        #expect(handle != 0)
        releaseScore(handle: handle)
    }

    @Test("metadata comes back")
    func metadataComesBack() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let metadata = try #require(scoreMetadata(handle: handle))
        #expect(metadata.title == "wasm bridge")
        #expect(metadata.composer == "test")
        #expect(metadata.openingQuarterBpm > 0)
    }

    @Test("metadata for an unknown handle is nil")
    func metadataForUnknownHandleIsNil() {
        #expect(scoreMetadata(handle: 999_999) == nil)
    }

    @Test("a released handle stops resolving")
    func releaseInvalidatesTheHandle() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        releaseScore(handle: handle)
        #expect(scoreMetadata(handle: handle) == nil)
    }

    @Test("releasing an unknown handle is safe")
    func releasingUnknownHandleIsSafe() {
        releaseScore(handle: 999_999)
    }

    @Test("the fingerprint is stable across two loads of the same bytes")
    func fingerprintIsStable() throws {
        let bytes = try SampleScore.mscz()
        let a = loadScore(bytes: jsBytes(bytes))
        let b = loadScore(bytes: jsBytes(bytes))
        defer {
            releaseScore(handle: a)
            releaseScore(handle: b)
        }
        #expect(scoreFingerprint(handle: a) == scoreFingerprint(handle: b))
        #expect(!scoreFingerprint(handle: a).isEmpty)
    }

    /// `Int` is 32 bits on wasm32 and `stableFingerprint` is a 64-bit digest, so
    /// the surface carries it as a decimal string. Reading it back pins that the
    /// whole value survived rather than half of it.
    @Test("the fingerprint survives the string round trip as a 64-bit value")
    func fingerprintRoundTripsAsInt64() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let score = try #require(scoreTable.value(for: Int64(handle)))
        #expect(Int64(scoreFingerprint(handle: handle)) == score.stableFingerprint)
    }

    @Test("the fingerprint of an unknown handle is empty")
    func fingerprintOfUnknownHandleIsEmpty() {
        #expect(scoreFingerprint(handle: 999_999).isEmpty)
    }

    /// Two scores with different notes must not collide, or the digest cannot
    /// serve as the "is the host's copy still the one I laid out" gate it exists
    /// to be.
    @Test("scores with different notes fingerprint differently")
    func differentNotesDiffer() throws {
        let a = try loadScore(bytes: jsBytes(SampleScore.mscz(pitches: [60, 62, 64, 65])))
        let b = try loadScore(bytes: jsBytes(SampleScore.mscz(pitches: [60, 62, 64, 67])))
        defer {
            releaseScore(handle: a)
            releaseScore(handle: b)
        }
        #expect(scoreFingerprint(handle: a) != scoreFingerprint(handle: b))
    }

    /// `Score.stableFingerprint` covers the mutable musical content and nothing
    /// else — its own doc comment says so, and `metaTags` is one of the things
    /// explicitly out of scope. Pinned here because a host reading
    /// "fingerprint" as "identity of this document" would be wrong in a way
    /// that only shows up as a stale cache being trusted.
    @Test("metadata is outside the fingerprint's scope")
    func metadataDoesNotAffectTheFingerprint() throws {
        let a = try loadScore(bytes: jsBytes(SampleScore.mscz(title: "one")))
        let b = try loadScore(bytes: jsBytes(SampleScore.mscz(title: "two")))
        defer {
            releaseScore(handle: a)
            releaseScore(handle: b)
        }
        #expect(scoreMetadata(handle: a)?.title != scoreMetadata(handle: b)?.title)
        #expect(scoreFingerprint(handle: a) == scoreFingerprint(handle: b))
    }
}
