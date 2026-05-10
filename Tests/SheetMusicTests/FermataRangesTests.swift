import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct FermataRangesTests {
    private func chord(_ pitch: Int = 60, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private func rest(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }

    private func fermata(
        _ subtype: String = "fermataAbove",
        stretch: Double? = nil
    ) -> VoiceElement {
        .fermata(Fermata(subtype: subtype, timeStretch: stretch))
    }

    private func staff(_ voiceElements: [[VoiceElement]]) -> Staff {
        let voices = voiceElements.map { Voice(elements: $0) }
        return Staff(measures: [Measure(voices: voices)])
    }

    // MARK: anchor: forward search (canonical MusicXML layout)

    @Test func forwardAnchorPicksNextChord() {
        let s = staff([[
            chord(60), // tick 0..480
            fermata("fermataAbove"), // anchors to D4
            chord(62), // tick 480..960
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    @Test func forwardAnchorAcrossDynamicAndKeySig() {
        let s = staff([[
            chord(60),
            fermata("fermataAbove"),
            .dynamic(Dynamic(subtype: "mf", velocity: 64)), // skipped
            chord(62),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 480, endTick: 960, stretch: 1.5)])
    }

    // MARK: anchor: backward fallback (MSCX after-chord layout)

    @Test func backwardFallbackPicksPreviousChord() {
        let s = staff([[
            chord(60), // tick 0..480
            fermata("fermataAbove"), // no chord after → fall back to C4
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: anchor: no chord → drop silently

    @Test func orphanFermataDropped() {
        let s = staff([[
            fermata("fermataAbove"), // no chord at all
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges.isEmpty)
    }

    // MARK: stretch: subtype default vs explicit

    @Test func longSubtypeUsesDefaultStretch() {
        let s = staff([[
            fermata("fermataLongAbove"),
            chord(60),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }

    @Test func explicitStretchOverridesSubtypeDefault() {
        let s = staff([[
            fermata("fermataAbove", stretch: 2.5),
            chord(60),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.5)])
    }

    // MARK: rest fermata applies (grand pause)

    @Test func restFermataYieldsRange() {
        let s = staff([[
            fermata("fermataAbove"),
            rest(.quarter),
        ]])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 1.5)])
    }

    // MARK: dedupe identical ranges across voices

    @Test func sameRangeAcrossVoicesDedupedToMaxStretch() {
        let s = staff([
            [fermata("fermataAbove"), chord(60)], // stretch 1.5 on [0,480)
            [fermata("fermataLongAbove"), chord(60)], // stretch 2.0 on [0,480)
        ])
        let ranges = FermataRanges.collect(from: s, division: 480)
        #expect(ranges == [FermataRange(startTick: 0, endTick: 480, stretch: 2.0)])
    }
}
