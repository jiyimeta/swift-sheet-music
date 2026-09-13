@testable import SheetMusicCore
import Testing

/// The extent a copy covers, for the regions a pair of slots cannot state.
///
/// `RangeCopySourceTests` covers the range entry point, whose extent always IS readable off two slots. This suite
/// is about the other entry point: a clipboard payload means "every staff I carry, over my own whole length", and
/// `Score.voiceElements(in:)` reads a `VoiceElementRange`'s staff span off the two bounds' staves and its tick
/// span off those same two bounds. Four facts, two slots — so unless one staff happens to stand at both temporal
/// extremes, something had to be surrendered. `RangeCopySource.Extent` states the four facts directly.
///
/// Split from `RangeCopySourceTests` for the `type_body_length` budget, which `Tests/.swiftlint.yml` does not
/// relax (only `file_length`).
@Suite("RangeCopySource extent")
struct RangeCopySourceExtentTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    /// Ordinary piano writing, as a payload: the LOWER staff alone stands at both temporal extremes, and it
    /// reaches them through two DIFFERENT elements — a quarter at the payload's first tick, a bar and a half of
    /// rest, then a half note still sounding after the upper staff has stopped. The upper staff touches neither
    /// extreme: it is silent through the whole of measure 0 (the boundary measure `RangeCopyPayload` trims away
    /// per staff, as `RangeCopySourceTests`' offset-entry fixture also shows) and its last note ends half a bar
    /// before the lower staff's.
    ///
    /// This is the scenario that survived both earlier approximations. Picking the two extremal slots by time
    /// rather than by staff address gets the ticks right and the staff span wrong; re-addressing one of them
    /// onto the staff the pair is missing gets the staff span right and pulls a tick in to that staff's own
    /// local extreme. Here that costs the lower staff its whole first measure.
    private static func pianoPayloadWhereOneStaffHoldsBothExtremes() -> Score {
        func quarter(_ pitch: Int) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
        }
        let timeSignature = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let upper = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [timeSignature])]),
            Measure(voices: [Voice(elements: [quarter(72), quarter(74)])]),
        ])
        let lower = Staff(defaultClefType: "F", measures: [
            Measure(voices: [Voice(elements: [
                timeSignature, quarter(48), .rest(duration: .quarter), .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])]),
            Measure(voices: [Voice(elements: [
                .rest(duration: .quarter), .rest(duration: .quarter),
                .chord(Chord(duration: .half, notes: [Note(pitch: 52, tpc: 14)])),
            ])]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [upper]),
            Part(id: "2", trackName: "Cello", instrument: Instrument(id: "cello"), staves: [lower]),
        ])
    }

    @Test("a payload whose lower staff alone holds both extremes keeps every staff AND the whole tick span")
    func oneStaffHoldingBothExtremesKeepsEveryStaffAndSpan() throws {
        let payload = Self.pianoPayloadWhereOneStaffHoldsBothExtremes()
        let source = try #require(RangeCopySource(payload: payload))
        #expect(source.startTick == 0)
        #expect(source.lengthTicks == 3840)
        #expect(Set(source.staves) == [Self.flute, Self.cello])
        #expect(source.streams.count == 2)
        let fluteStream = try #require(source.streams.first { $0.staff == Self.flute })
        let celloStream = try #require(source.streams.first { $0.staff == Self.cello })
        // Under the two-slot approximation the cello's whole measure 0 — its true earliest onset included — is
        // silently dropped, and the span starts at 1920 instead of 0.
        #expect(celloStream.elements.map(\.absoluteTick) == [0, 480, 960, 1440, 1920, 2400, 2880])
        #expect(celloStream.elements.map(\.lengthTicks) == [480, 480, 480, 480, 480, 480, 960])
        #expect(fluteStream.elements.map(\.absoluteTick) == [1920, 2400])
    }
}
