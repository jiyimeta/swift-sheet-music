import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private func voiceScore(_ inner: String) throws -> Score {
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

private func firstVoiceElements(in score: Score) -> [VoiceElement] {
    score.parts[0].staves[0].measures[0].voices[0].elements
}

/// Voice fragments use a whole-score envelope because sticking and expression
/// are segment annotations in the voice stream, not chord- or note-owned data.
private func voiceElements(_ inner: String) throws -> [VoiceElement] {
    try firstVoiceElements(in: voiceScore(inner))
}

private func betweenChords(_ annotations: String) -> String {
    """
    <Chord>
      <durationType>quarter</durationType>
      <Note><pitch>60</pitch><tpc>14</tpc></Note>
    </Chord>
    \(annotations)
    <Chord>
      <durationType>quarter</durationType>
      <Note><pitch>62</pitch><tpc>16</tpc></Note>
    </Chord>
    """
}

@Suite("Voice annotation model")
struct VoiceAnnotationModelTests {
    @Test func stickingDefaults() {
        let sticking = Sticking(text: "R")
        #expect(sticking.visible)
        #expect(sticking.preservedMarkup.isEmpty)
    }

    @Test func expressionDefaults() {
        let expression = ExpressionText(text: "dolce")
        #expect(expression.snapToDynamics == nil)
        #expect(expression.visible)
        #expect(expression.preservedMarkup.isEmpty)
    }

    @Test func visibilityWritesThroughToElementProperties() {
        var sticking = Sticking(text: "R")
        sticking.visible = false
        #expect(!sticking.elementProperties.visible)

        var expression = ExpressionText(text: "dolce")
        expression.visible = false
        #expect(!expression.elementProperties.visible)
    }

    @Test func setElementVisibleReadsAndSetsBothAnnotationTypes() throws {
        var score = try voiceScore(betweenChords("""
        <Sticking><text>R</text></Sticking>
        <Expression><text>dolce</text></Expression>
        """))
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let stickingID = VoiceElementID(
            staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        let expressionID = VoiceElementID(
            staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )
        #expect(SetElementVisible.current(at: stickingID, in: score) == true)
        #expect(SetElementVisible.current(at: expressionID, in: score) == true)

        _ = try SetElementVisible(at: stickingID, visible: false).apply(to: &score)
        _ = try SetElementVisible(at: expressionID, visible: false).apply(to: &score)
        guard case let .sticking(sticking)? = score[stickingID],
              case let .expression(expression)? = score[expressionID]
        else {
            Issue.record("expected sticking and expression annotations")
            return
        }
        #expect(!sticking.visible)
        #expect(!expression.visible)
        #expect(SetElementVisible.current(at: stickingID, in: score) == false)
        #expect(SetElementVisible.current(at: expressionID, in: score) == false)
    }

    private func fingerprint(_ element: VoiceElement) -> UInt64 {
        var hasher = FNV1a()
        hasher.combine(element)
        return hasher.value
    }

    @Test func fingerprintSeparatesAnnotationCasesAndPayloads() {
        let stickingR = fingerprint(.sticking(Sticking(text: "R")))
        let stickingL = fingerprint(.sticking(Sticking(text: "L")))
        #expect(stickingR != stickingL)

        let expressionR = fingerprint(.expression(ExpressionText(text: "R")))
        #expect(stickingR != expressionR)

        let snapStates = [
            fingerprint(.expression(ExpressionText(text: "dolce"))),
            fingerprint(.expression(ExpressionText(text: "dolce", snapToDynamics: false))),
            fingerprint(.expression(ExpressionText(text: "dolce", snapToDynamics: true))),
        ]
        #expect(Set(snapStates).count == 3)

        var hidden = Sticking(text: "R")
        hidden.visible = false
        #expect(stickingR != fingerprint(.sticking(hidden)))
    }
}

@Suite("Voice annotation MSCX round trip")
struct VoiceAnnotationMSCXTests {
    @Test func decodesBareStickingAtItsVoicePosition() throws {
        let elements = try voiceElements(betweenChords("""
        <Sticking><text>R</text></Sticking>
        """))
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .sticking(sticking) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, sticking, chord")
            return
        }
        #expect(sticking == Sticking(text: "R"))
    }

    @Test func decodesBareExpressionAtItsVoicePosition() throws {
        let elements = try voiceElements(betweenChords("""
        <Expression><text>dolce</text></Expression>
        """))
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .expression(expression) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, expression, chord")
            return
        }
        #expect(expression.text == "dolce")
        #expect(expression.snapToDynamics == nil)
    }

    @Test func decodesExplicitSnapToDynamicsValues() throws {
        let elements = try voiceElements(betweenChords("""
        <Expression><snapToDynamics>0</snapToDynamics><text>dolce</text></Expression>
        <Expression><snapToDynamics>1</snapToDynamics><text>forte</text></Expression>
        """))
        try #require(elements.count == 4)
        guard case let .expression(unsnapped) = elements[1],
              case let .expression(snapped) = elements[2]
        else {
            Issue.record("expected two expression annotations")
            return
        }
        #expect(unsnapped.snapToDynamics == false)
        #expect(snapped.snapToDynamics == true)
    }

    @Test func keepsPlainTextStyleAsPreservedMarkup() throws {
        let elements = try voiceElements(betweenChords("""
        <Sticking><style>sticking</style><text>R</text></Sticking>
        """))
        try #require(elements.count == 3)
        guard case let .sticking(sticking) = elements[1] else {
            Issue.record("expected sticking annotation")
            return
        }
        #expect(sticking.preservedMarkup.map(\.name) == ["style"])
    }

    @Test func keepsPlacementAndOffsetInSourceOrder() throws {
        let elements = try voiceElements(betweenChords("""
        <Expression>
          <text>dolce</text>
          <placement>above</placement>
          <offset x="0" y="1"/>
        </Expression>
        """))
        try #require(elements.count == 3)
        guard case let .expression(expression) = elements[1] else {
            Issue.record("expected expression annotation")
            return
        }
        #expect(expression.preservedMarkup.map(\.name) == ["placement", "offset"])
        let placement = try #require(expression.preservedMarkup.first)
        let offset = try #require(expression.preservedMarkup.last)
        #expect(placement.text == "above")
        #expect(offset.attributes == ["x": "0", "y": "1"])
    }

    /// MuseScore 4.4+ writes an `Expression`'s vertical side as `<direction>`,
    /// not `<placement>`, because `Expression::hasVoiceAssignmentProperties()`
    /// is true and `writeItemProperties` skips `<placement>` for such an item
    /// (`rw/write/twrite.cpp`). Both spellings occur in real files and both are
    /// unmodeled, so both must ride through as preserved markup.
    @Test func keepsVoiceAssignmentPropertiesAsPreservedMarkup() throws {
        let elements = try voiceElements(betweenChords("""
        <Expression>
          <voiceAssignment>allVoiceInInstrument</voiceAssignment>
          <direction>up</direction>
          <text>dolce</text>
        </Expression>
        """))
        try #require(elements.count == 3)
        guard case let .expression(expression) = elements[1] else {
            Issue.record("expected expression annotation")
            return
        }
        #expect(expression.text == "dolce")
        #expect(expression.preservedMarkup.map(\.name) == ["voiceAssignment", "direction"])
        #expect(expression.preservedMarkup.last?.text == "up")
    }

    @Test func consumesVisibilityInsteadOfPreservingIt() throws {
        let elements = try voiceElements(betweenChords("""
        <Sticking><text>R</text><visible>0</visible></Sticking>
        <Expression><text>dolce</text><visible>0</visible></Expression>
        """))
        try #require(elements.count == 4)
        guard case let .sticking(sticking) = elements[1],
              case let .expression(expression) = elements[2]
        else {
            Issue.record("expected sticking and expression annotations")
            return
        }
        #expect(!sticking.visible)
        #expect(sticking.preservedMarkup.isEmpty)
        #expect(!expression.visible)
        #expect(expression.preservedMarkup.isEmpty)
    }

    @Test func flattensInlineMarkupInTheText() throws {
        // Inline font markup is lost through the parity doc's §7.1
        // cross-cutting text-content gap; the reader-visible text is modeled.
        let elements = try voiceElements(betweenChords("""
        <Sticking><text><font size="8"/>R</text></Sticking>
        """))
        try #require(elements.count == 3)
        guard case let .sticking(sticking) = elements[1] else {
            Issue.record("expected sticking annotation")
            return
        }
        #expect(sticking.text == "R")
    }

    @Test func encodesCanonicalChildShapes() {
        let sticking = Sticking(text: "R").encode()
        #expect(sticking.name == "Sticking")
        #expect(sticking.children.map(\.name) == ["text"])

        var hiddenSticking = Sticking(text: "R")
        hiddenSticking.visible = false
        #expect(hiddenSticking.encode().children.map(\.name) == ["text", "visible"])

        let expression = ExpressionText(text: "dolce").encode()
        #expect(expression.name == "Expression")
        #expect(expression.children.map(\.name) == ["text"])

        let explicitSnap = ExpressionText(text: "dolce", snapToDynamics: false).encode()
        #expect(explicitSnap.children.map(\.name) == ["snapToDynamics", "text"])
        #expect(explicitSnap.first("snapToDynamics")?.text == "0")
    }

    @Test func wholeScoreRoundTripPreservesPositionAndPayload() throws {
        let first = try voiceScore(betweenChords("""
        <Sticking><text>R</text><placement>below</placement></Sticking>
        <Expression><snapToDynamics>0</snapToDynamics><text>dolce</text></Expression>
        """))
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(first))
        #expect(firstVoiceElements(in: reparsed) == firstVoiceElements(in: first))
    }

    @Test func strippingPreservedMarkupClearsBothAnnotationBags() throws {
        let score = try voiceScore(betweenChords("""
        <Sticking><text>R</text><placement>below</placement></Sticking>
        <Expression><text>dolce</text><offset x="0" y="1"/></Expression>
        """))
        let original = firstVoiceElements(in: score)
        try #require(original.count == 4)
        guard case let .sticking(originalSticking) = original[1],
              case let .expression(originalExpression) = original[2]
        else {
            Issue.record("expected sticking and expression annotations")
            return
        }
        #expect(!originalSticking.preservedMarkup.isEmpty)
        #expect(!originalExpression.preservedMarkup.isEmpty)

        let stripped = firstVoiceElements(in: score.strippingPreservedMarkup())
        guard case let .sticking(sticking) = stripped[1],
              case let .expression(expression) = stripped[2]
        else {
            Issue.record("expected stripped sticking and expression annotations")
            return
        }
        #expect(sticking.preservedMarkup.isEmpty)
        #expect(expression.preservedMarkup.isEmpty)
    }
}

@Suite("Voice annotation fixture")
struct VoiceAnnotationFixtureTests {
    /// The preservation gate `continue`s past a fixture it cannot parse, so
    /// this proves `voice-annotations.mscx` is actually read and every
    /// annotation it carries reaches the model.
    @Test func fixtureDecodesEveryAnnotationItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("voice-annotations"))
        let part = try #require(score.parts.first)
        let staff = try #require(part.staves.first)
        try #require(staff.measures.count == 3)

        let first = staff.measures[0].voices[0].elements
        try #require(first.count == 5)
        guard case .timeSignature = first[0],
              case let .sticking(right) = first[1],
              case .chord = first[2],
              case let .sticking(left) = first[3],
              case .chord = first[4]
        else {
            Issue.record("measure 0 element sequence did not match the fixture")
            return
        }
        #expect(right.text == "R")
        #expect(left.text == "L")
        #expect(left.preservedMarkup.map(\.name) == ["placement"])

        let second = staff.measures[1].voices[0].elements
        try #require(second.count == 4)
        guard case let .expression(dolce) = second[0],
              case .chord = second[1],
              case let .expression(espressivo) = second[2],
              case .chord = second[3]
        else {
            Issue.record("measure 1 element sequence did not match the fixture")
            return
        }
        #expect(dolce.text == "dolce")
        #expect(dolce.snapToDynamics == nil)
        #expect(espressivo.text == "espressivo")
        #expect(espressivo.snapToDynamics == false)
        #expect(espressivo.preservedMarkup.map(\.name) == ["offset"])
        let offset = try #require(espressivo.preservedMarkup.first)
        #expect(offset.attributes["x"] == "0")
        #expect(offset.attributes["y"] == "2.5")

        let third = staff.measures[2].voices[0].elements
        try #require(third.count == 2)
        guard case let .sticking(hidden) = third[0],
              case .chord = third[1]
        else {
            Issue.record("measure 2 element sequence did not match the fixture")
            return
        }
        #expect(hidden.text == "R")
        #expect(!hidden.visible)
        #expect(hidden.preservedMarkup.map(\.name) == ["style"])
    }
}
