import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private func tabAnnotationScore(_ inner: String) throws -> Score {
    try MSCXParser.parse(Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part>
          <Staff id="1"/>
          <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
        </Part>
        <Staff id="1">
          <Measure>
            <voice>
              \(inner)
            </voice>
          </Measure>
        </Staff>
      </Score>
    </museScore>
    """.utf8))
}

private func firstTabVoiceElements(in score: Score) -> [VoiceElement] {
    score.parts[0].staves[0].measures[0].voices[0].elements
}

/// These fragments need a score envelope because capo and string tunings are
/// staff-bound segment annotations in a voice stream.
private func tabVoiceElements(_ inner: String) throws -> [VoiceElement] {
    try firstTabVoiceElements(in: tabAnnotationScore(inner))
}

private func tabBetweenChords(_ annotations: String) -> String {
    """
    <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
    \(annotations)
    <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
    """
}

@Suite("Tab annotation model")
struct TabAnnotationModelTests {
    @Test func capoDefaultsMatchMuseScorePropertyDefaults() {
        // The first three are MuseScore 4.6 `Capo::propertyDefault` values,
        // deliberately not the opposite upstream field initializers. `nil`
        // records that the 4.7-only transpose tag was absent.
        let capo = Capo(text: "")
        #expect(capo.isActive)
        #expect(capo.fretPosition == 1)
        #expect(capo.generatesText)
        #expect(capo.transposeMode == nil)
        #expect(capo.ignoredStrings.isEmpty)
    }

    @Test func transposeModesRoundTripKnownAndUnknownOrdinals() {
        #expect(Capo.TransposeMode(mscxOrdinal: 0) == .playbackOnly)
        #expect(Capo.TransposeMode(mscxOrdinal: 1) == .standardOnly)
        #expect(Capo.TransposeMode(mscxOrdinal: 2) == .tabOnly)
        #expect(Capo.TransposeMode.playbackOnly.mscxOrdinal == 0)
        #expect(Capo.TransposeMode.standardOnly.mscxOrdinal == 1)
        #expect(Capo.TransposeMode.tabOnly.mscxOrdinal == 2)
        let unknown = Capo.TransposeMode(mscxOrdinal: 7)
        #expect(unknown == .other(rawValue: 7))
        #expect(unknown.mscxOrdinal == 7)
    }

    @Test func stringTuningsDefaultsAreEmpty() {
        let tunings = StringTunings()
        #expect(tunings.preset.isEmpty)
        #expect(tunings.visibleStrings.isEmpty)
        #expect(tunings.stringData == nil)
    }

    @Test func visibilityWritesThroughToElementProperties() {
        var capo = Capo(text: "Capo 2")
        capo.visible = false
        #expect(!capo.visible)
        #expect(!capo.elementProperties.visible)

        var tunings = StringTunings(preset: "Drop D")
        tunings.visible = false
        #expect(!tunings.visible)
        #expect(!tunings.elementProperties.visible)
    }

    @Test func setElementVisibleReadsAndSetsBothTabAnnotationTypes() throws {
        var score = try tabAnnotationScore(tabBetweenChords("""
        <Capo><text>Capo 2</text></Capo>
        <StringTunings><preset>Drop D</preset><visibleStrings/><text>Drop D</text></StringTunings>
        """))
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let capoID = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let tuningsID = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        #expect(SetElementVisible.current(at: capoID, in: score) == true)
        #expect(SetElementVisible.current(at: tuningsID, in: score) == true)

        _ = try SetElementVisible(at: capoID, visible: false).apply(to: &score)
        _ = try SetElementVisible(at: tuningsID, visible: false).apply(to: &score)
        guard case let .capo(capo)? = score[capoID],
              case let .stringTunings(tunings)? = score[tuningsID]
        else {
            Issue.record("expected capo and string-tunings annotations")
            return
        }
        #expect(!capo.visible)
        #expect(!tunings.visible)
        #expect(SetElementVisible.current(at: capoID, in: score) == false)
        #expect(SetElementVisible.current(at: tuningsID, in: score) == false)
    }

    private func fingerprint(_ element: VoiceElement) -> UInt64 {
        var hasher = FNV1a()
        hasher.combine(element)
        return hasher.value
    }

    @Test func fingerprintsCoverCapoAndStringTuningSemantics() {
        let capo = fingerprint(.capo(Capo(text: "same")))
        #expect(capo != fingerprint(.capo(Capo(fretPosition: 2, text: "same"))))
        #expect(capo != fingerprint(.capo(Capo(transposeMode: .playbackOnly, text: "same"))))
        #expect(capo != fingerprint(.capo(Capo(transposeMode: .tabOnly, text: "same"))))
        #expect(capo != fingerprint(.capo(Capo(ignoredStrings: [1], text: "same"))))

        var ascending = Set<Int>()
        ascending.insert(1)
        ascending.insert(5)
        var descending = Set<Int>()
        descending.insert(5)
        descending.insert(1)
        #expect(
            fingerprint(.capo(Capo(ignoredStrings: ascending, text: "same")))
                == fingerprint(.capo(Capo(ignoredStrings: descending, text: "same"))),
        )

        #expect(capo != fingerprint(.stringTunings(StringTunings(preset: "same"))))
        let ordered = fingerprint(.stringTunings(StringTunings(visibleStrings: [0, 1])))
        let reversed = fingerprint(.stringTunings(StringTunings(visibleStrings: [1, 0])))
        #expect(ordered != reversed)

        let eightNULs = String(repeating: "\0", count: 8)
        let capoList = fingerprint(.capo(Capo(ignoredStrings: [8], text: "")))
        let capoText = fingerprint(.capo(Capo(text: eightNULs)))
        #expect(capoList != capoText)
        let tuningsList = fingerprint(.stringTunings(StringTunings(visibleStrings: [8])))
        let tuningsText = fingerprint(.stringTunings(StringTunings(text: eightNULs)))
        #expect(tuningsList != tuningsText)
    }
}

@Suite("Tab annotation MSCX round trip")
struct TabAnnotationMSCXTests {
    @Test func decodesBareCapoAtItsVoicePositionWithPropertyDefaults() throws {
        let elements = try tabVoiceElements(tabBetweenChords("""
        <Capo><fretPosition>2</fretPosition><text>Capo 2</text></Capo>
        """))
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .capo(capo) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, capo, chord")
            return
        }
        #expect(capo.fretPosition == 2)
        #expect(capo.text == "Capo 2")
        #expect(capo.isActive)
        #expect(capo.generatesText)
        #expect(capo.transposeMode == nil)
    }

    @Test func missingAndMalformedFretPositionsRemainDistinct() throws {
        let elements = try tabVoiceElements("""
        <Capo><text>Absent</text></Capo>
        <Capo><fretPosition>abc</fretPosition><text>Malformed</text></Capo>
        """)
        try #require(elements.count == 2)
        guard case let .capo(absent) = elements[0],
              case let .capo(malformed) = elements[1]
        else {
            Issue.record("expected two capo annotations")
            return
        }
        #expect(absent.fretPosition == 1)
        #expect(absent.transposeMode == nil)
        #expect(malformed.fretPosition == 0)
    }

    @Test func emptyCapoUsesAllFileDefaultsAndIsIdempotent() throws {
        let elements = try tabVoiceElements("<Capo/>")
        guard case let .capo(capo) = try #require(elements.first) else {
            Issue.record("expected capo annotation")
            return
        }
        #expect(capo.isActive)
        #expect(capo.fretPosition == 1)
        #expect(capo.generatesText)
        #expect(capo.transposeMode == nil)
        #expect(capo.ignoredStrings.isEmpty)
        #expect(capo.text.isEmpty)
        #expect(Capo.decode(capo.encode()) == capo)
    }

    @Test func distinguishesAbsentBooleansFromExplicitZero() throws {
        let elements = try tabVoiceElements("""
        <Capo><active>0</active><generateText>0</generateText><text>Manual</text></Capo>
        """)
        guard case let .capo(capo) = try #require(elements.first) else {
            Issue.record("expected capo annotation")
            return
        }
        #expect(!capo.isActive)
        #expect(!capo.generatesText)
    }

    @Test func recordsOnlyStringsWhoseApplyFlagIsFalse() throws {
        let elements = try tabVoiceElements("""
        <Capo>
          <string no="3"><apply>0</apply></string>
          <string no="4"><apply>1</apply></string>
          <text>Partial capo</text>
        </Capo>
        """)
        guard case let .capo(capo) = try #require(elements.first) else {
            Issue.record("expected capo annotation")
            return
        }
        #expect(capo.ignoredStrings == [3])
    }

    @Test func decodesKnownAndUnknownTransposeModes() throws {
        let elements = try tabVoiceElements("""
        <Capo><transposeMode>2</transposeMode><text>Tab</text></Capo>
        <Capo><transposeMode>7</transposeMode><text>Future</text></Capo>
        """)
        try #require(elements.count == 2)
        guard case let .capo(tabOnly) = elements[0],
              case let .capo(unknown) = elements[1]
        else {
            Issue.record("expected two capo annotations")
            return
        }
        #expect(tabOnly.transposeMode == .tabOnly)
        #expect(unknown.transposeMode == .other(rawValue: 7))
    }

    @Test func decodesStringTuningsThroughTheSharedStringDataModel() throws {
        let elements = try tabVoiceElements("""
        <StringTunings>
          <preset>Drop D</preset>
          <visibleStrings>0,1,2</visibleStrings>
          <StringData>
            <frets>19</frets>
            <string>38</string><string>45</string><string>50</string>
          </StringData>
          <text>Drop D</text>
        </StringTunings>
        """)
        guard case let .stringTunings(tunings) = try #require(elements.first) else {
            Issue.record("expected string-tunings annotation")
            return
        }
        #expect(tunings.preset == "Drop D")
        #expect(tunings.visibleStrings == [0, 1, 2])
        #expect(tunings.stringData?.frets == 19)
        #expect(tunings.stringData?.strings.map(\.pitch) == [38, 45, 50])
    }

    @Test func absentStringDataAndEmptyVisibleStringsStayEmpty() throws {
        let elements = try tabVoiceElements("""
        <StringTunings><preset/><visibleStrings></visibleStrings><text/></StringTunings>
        """)
        guard case let .stringTunings(tunings) = try #require(elements.first) else {
            Issue.record("expected string-tunings annotation")
            return
        }
        #expect(tunings.stringData == nil)
        #expect(tunings.visibleStrings.isEmpty)
    }

    @Test func preservesTextBaseAndStaffTextBaseTagsInSourceOrder() throws {
        let elements = try tabVoiceElements("""
        <Capo>
          <placement>above</placement>
          <text>Capo 2</text>
          <style>capo</style>
          <channelSwitch>pizzicato</channelSwitch>
        </Capo>
        """)
        guard case let .capo(capo) = try #require(elements.first) else {
            Issue.record("expected capo annotation")
            return
        }
        #expect(capo.preservedMarkup.map(\.name) == ["placement", "style", "channelSwitch"])
    }

    @Test func encodesCanonicalChildShapesAndSortedIgnoredStrings() throws {
        let capo = Capo(text: "Capo 2").encode()
        #expect(capo.name == "Capo")
        #expect(capo.children.map(\.name) == [
            "active", "fretPosition", "generateText", "text",
        ])

        let tabOnly = Capo(transposeMode: .tabOnly, text: "Capo 2").encode()
        #expect(tabOnly.children.map(\.name) == [
            "active", "fretPosition", "generateText", "transposeMode", "text",
        ])
        #expect(tabOnly.first("transposeMode")?.text == "2")

        let partial = Capo(ignoredStrings: [5, 1], text: "Partial capo").encode()
        let strings = partial.all("string")
        #expect(strings.compactMap { $0.attributes["no"] } == ["1", "5"])
        #expect(strings.allSatisfy { $0.first("apply")?.text == "0" })

        let tunings = StringTunings().encode()
        let visibleStrings = try #require(tunings.first("visibleStrings"))
        #expect(visibleStrings.text.isEmpty)
    }

    @Test func wholeScoreRoundTripPreservesBothAnnotationValues() throws {
        let first = try tabAnnotationScore(tabBetweenChords("""
        <Capo><fretPosition>2</fretPosition><text>Capo 2</text><placement>above</placement></Capo>
        <StringTunings>
          <preset>Drop D</preset><visibleStrings>0,1,2</visibleStrings>
          <StringData><frets>19</frets><string>38</string><string>45</string></StringData>
          <text>Drop D</text>
        </StringTunings>
        """))
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(first))
        #expect(firstTabVoiceElements(in: reparsed) == firstTabVoiceElements(in: first))
    }
}

@Suite("Tab annotation fixture")
struct TabAnnotationFixtureTests {
    /// The preservation gate skips an unreadable fixture, so this proves the
    /// fixture parses and every annotation it carries reaches the model.
    @Test func fixtureDecodesEveryAnnotationItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tab-annotations"))
        let part = try #require(score.parts.first)
        let staff = try #require(part.staves.first)
        try #require(staff.measures.count == 3)

        let first = try #require(staff.measures[0].voices.first).elements
        try #require(first.count == 3)
        guard case .timeSignature = first[0],
              case let .capo(firstCapo) = first[1],
              case .chord = first[2]
        else {
            Issue.record("measure 0 element sequence did not match the fixture")
            return
        }
        #expect(firstCapo.fretPosition == 2)
        #expect(firstCapo.isActive)
        #expect(firstCapo.generatesText)
        #expect(firstCapo.text == "Capo 2")

        let second = try #require(staff.measures[1].voices.first).elements
        try #require(second.count == 2)
        guard case let .stringTunings(tunings) = second[0],
              case .chord = second[1]
        else {
            Issue.record("measure 1 element sequence did not match the fixture")
            return
        }
        #expect(tunings.preset == "Drop D")
        #expect(tunings.visibleStrings == [0, 1, 2, 3, 4, 5])
        #expect(tunings.stringData?.frets == 19)
        #expect(tunings.stringData?.strings.first?.pitch == 38)

        let third = try #require(staff.measures[2].voices.first).elements
        try #require(third.count == 2)
        guard case let .capo(lastCapo) = third[0],
              case .chord = third[1]
        else {
            Issue.record("measure 2 element sequence did not match the fixture")
            return
        }
        #expect(!lastCapo.isActive)
        #expect(lastCapo.fretPosition == 5)
        #expect(!lastCapo.generatesText)
        #expect(lastCapo.transposeMode == nil)
        #expect(lastCapo.ignoredStrings == [0, 5])
        #expect(lastCapo.preservedMarkup.map(\.name) == ["placement"])

        let instrumentTuning = try #require(part.instrument.stringData)
        #expect(instrumentTuning.frets == 19)
        #expect(instrumentTuning.strings.map(\.pitch) == [40, 45, 50, 55, 59, 64])
    }
}
