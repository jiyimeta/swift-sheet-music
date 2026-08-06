import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

@Suite("InstrumentChange MusicXML")
struct InstrumentChangeMusicXMLTests {
    static func fixture() throws -> Score {
        let url = try #require(
            Bundle.module.url(
                forResource: "instrument-change", withExtension: "musicxml",
            ),
            "fixture not bundled: instrument-change.musicxml",
        )
        return try MusicXMLParser.parse(Data(contentsOf: url))
    }

    @Test("the part's timeline is piano then accordion")
    func timelineMatchesTheMSCXPath() throws {
        let timeline = try Self.fixture().instrumentTimeline(forPart: 0)
        #expect(timeline.count == 2)
        #expect(timeline[0].instrument.channel.program == 0)
        #expect(timeline[1].instrument.channel.program == 21)
        #expect(timeline[1].measureIndex == 2)

        // The synthesized change's `instrument` is resolved from the
        // per-id table (`decodeInstrumentTable`/`decodeChannel`), unlike
        // `timeline[0]` which carries the part's default `InstrumentChannel`
        // — so these three lines are the only place the accordion's real
        // MusicXML → InstrumentChannel conversions are exercised end to
        // end through the public `Score` API.
        // <midi-channel>2</midi-channel> is 1-based → 0-based `midiChannel`.
        #expect(timeline[1].instrument.channel.midiChannel == 1)
        // <volume>78.7402</volume> is a 0-100 percentage → MIDI CC 7's
        // 0-127. 78.7402% of 127 is exactly 100 — MuseScore's own default
        // volume — so this also sanity-checks the formula is the right one,
        // not just present.
        #expect(timeline[1].instrument.channel.volume == 100)
        // <pan>0</pan> is -90…90 degrees → 0-127 with 64 as center.
        #expect(timeline[1].instrument.channel.pan == 64)
    }

    /// Finding 1 (round 1 review): only `program` was pinned anywhere,
    /// but the live dedup rule
    /// (`Sources/SheetMusicCore/Score/InstrumentChannel.swift`'s
    /// `program`/`bank`/`volume`/`pan`/`reverb`/`chorus` equality check)
    /// keys on every field. `timelineMatchesTheMSCXPath` above only
    /// reaches the accordion's (the second, changed-to instrument's)
    /// derived channel — the piano's (the first, part-seed instrument's)
    /// derived channel is never exposed through `Score.instrumentTimeline`
    /// (the seed point uses the part's default `InstrumentChannel`, not
    /// the per-id table). Call `Part.decodeMusicXML` directly — already
    /// `internal`, no new API — to pin both instruments' conversions from
    /// the same fixture's `<score-part>`.
    @Test("midi-instrument unit conversions are correct for both instruments")
    func midiInstrumentConversionsForBothInstruments() throws {
        let url = try #require(
            Bundle.module.url(forResource: "instrument-change", withExtension: "musicxml"),
        )
        let root = try XMLTreeParser.parse(Data(contentsOf: url))
        let scorePart = try #require(root.first("part-list")?.first("score-part"))
        let (_, _, byID) = try Part.decodeMusicXML(
            scorePart: scorePart, partId: "P1", staffCount: 1,
        )
        let piano = try #require(byID["P1-I1"])
        let accordion = try #require(byID["P1-I2"])

        // <midi-program> is 1-based in MusicXML → 0-based `program`.
        #expect(piano.channel.program == 0) // <midi-program>1</midi-program>
        #expect(accordion.channel.program == 21) // <midi-program>22</midi-program>

        // <midi-channel> is 1-based → 0-based `midiChannel`.
        #expect(piano.channel.midiChannel == 0) // <midi-channel>1</midi-channel>
        #expect(accordion.channel.midiChannel == 1) // <midi-channel>2</midi-channel>

        // <volume> is a 0-100 percentage → MIDI CC 7's 0-127. Both
        // instruments carry the fixture's <volume>78.7402</volume>, which
        // lands on exactly 100 — MuseScore's own default volume, so this
        // doubles as a sanity check that the conversion (not a copy of the
        // raw percentage) is what's running.
        #expect(piano.channel.volume == 100)
        #expect(accordion.channel.volume == 100)

        // <pan> is -90…90 degrees → 0-127 with 64 as center. Both
        // instruments carry the fixture's <pan>0</pan>.
        #expect(piano.channel.pan == 64)
        #expect(accordion.channel.pan == 64)
    }

    @Test("originalStaff is stamped so the change is part-scoped")
    func originalStaffIsSet() throws {
        let score = try Self.fixture()
        let stamped = score.systemMeasures.flatMap(\.elements).filter {
            if case .instrumentChange = $0.element { return true }
            return false
        }
        #expect(!stamped.isEmpty)
        // MidiRenderer routes a nil originalStaff to staff (0,0), which
        // would silently re-instrument part 0.
        #expect(stamped.allSatisfy { $0.originalStaff != nil })
    }

    @Test("a part whose notes never switch id gets no change")
    func noSpuriousChanges() throws {
        let url = try #require(
            Bundle.module.url(forResource: "glissando-wavy", withExtension: "musicxml"),
        )
        let score = try MusicXMLParser.parse(Data(contentsOf: url))
        let changes = score.systemMeasures.flatMap(\.elements).count {
            if case .instrumentChange = $0.element { return true }
            return false
        }
        #expect(changes == 0)
    }

    /// Finding 2 (round 1 review): a `<note><instrument id>` (or an
    /// explicit `<instrument-change id>`) naming an id no
    /// `<score-instrument>` declares used to drop the whole synthesized
    /// change. `InstrumentChange.instrument` is `Instrument?` precisely
    /// so a change with no usable instrument still carries its text (see
    /// the type's doc comment, and how the MSCX decoder already honors
    /// this contract) — the MusicXML path should do the same rather than
    /// silently dropping the element. There is no MusicXML diagnostics
    /// channel to also report this on (`ScoreDiagnostic` /
    /// `parseWithDiagnostics` are MSCX-only); that's a separate, later
    /// design decision, not addressed here.
    @Test("an unresolved <instrument id> still engraves, contributing no timeline point")
    func unresolvedInstrumentIDStillEngraves() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <part-name>Test</part-name>
              <score-instrument id="P1-I1">
                <instrument-name>Test Instrument</instrument-name>
              </score-instrument>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>4</duration>
                <instrument id="P1-I1"/>
                <voice>1</voice>
                <type>whole</type>
              </note>
            </measure>
            <measure number="2">
              <note>
                <pitch><step>D</step><octave>4</octave></pitch>
                <duration>4</duration>
                <instrument id="P1-I2"/>
                <voice>1</voice>
                <type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        let changes: [InstrumentChange] = score.systemMeasures.flatMap(\.elements).compactMap {
            guard case let .instrumentChange(change) = $0.element else { return nil }
            return change
        }
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.instrument == nil)
        #expect(!change.text.isEmpty)
        #expect(change.isUserInitialized == false)

        // A nil-instrument change contributes no point — playback and
        // channel allocation are unaffected by the malformed reference.
        // Only the part-seed point (measureIndex 0) remains.
        let timeline = score.instrumentTimeline(forPart: 0)
        #expect(timeline.count == 1)
    }
}
