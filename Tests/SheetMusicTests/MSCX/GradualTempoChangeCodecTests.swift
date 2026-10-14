import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A `<Spanner type="GradualTempoChange">` decodes as `.gradualTempoChange` with its payload — type, factor, easing,
/// play — and the payload's other children kept for the encoder; `<continueText>` and `<endText>` are modeled on every
/// line spanner.
@Suite("Gradual tempo change codec")
struct GradualTempoChangeCodecTests {
    private static func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-gradual"))
    }

    /// The begin sides (the spanners carrying a payload) of the fixture's staff, in score order.
    private static func changes(_ score: Score) -> [Spanner] {
        score.parts[0].staves[0].measures.flatMap { measure in
            measure.voices.flatMap(\.elements.values).compactMap { element -> Spanner? in
                guard case let .spanner(spanner) = element, spanner.gradualTempoChange != nil else { return nil }
                return spanner
            }
        }
    }

    @Test("a rit. decodes as a gradual tempo change with its payload and texts")
    func decodesKindAndPayload() throws {
        let rit = try #require(Self.changes(Self.fixture()).first)
        #expect(rit.kind == .gradualTempoChange)
        let payload = try #require(rit.gradualTempoChange)
        #expect(payload.type == .ritardando)
        #expect(payload.factor == nil)
        #expect(payload.effectiveFactor == 0.75)
        #expect(payload.easing == .normal)
        #expect(payload.playsBack)
        #expect(rit.beginText == "rit.")
        #expect(rit.continueText == "(rit.)")
        #expect(payload.preservedMarkup.map(\.name)
            == ["beginHookHeight", "endHookType", "endHookHeight", "beginTextOffset"])
    }

    @Test("easing, an explicit factor, a mid-measure end and a muted change decode")
    func easingFactorAndPlay() throws {
        let changes = try Self.changes(Self.fixture())
        try #require(changes.count == 3)
        let accel = try #require(changes[1].gradualTempoChange)
        #expect(accel.type == .accelerando)
        #expect(accel.easing == .easeIn)
        #expect(accel.factor == 1.5)
        #expect(changes[1].nextMeasuresOffset == 1)
        #expect(changes[1].nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(changes[2].gradualTempoChange?.playsBack == false)
    }

    @Test("each type's default factor is MuseScore's")
    func defaultFactors() {
        let expected: [GradualTempoChangeType: Double] = [
            .undefined: 1, .accelerando: 1.33, .allargando: 0.75, .calando: 0.5, .lentando: 0.75, .morendo: 0.5,
            .precipitando: 1.15, .rallentando: 0.75, .ritardando: 0.75, .smorzando: 0.5, .sostenuto: 0.95,
            .stringendo: 1.5,
        ]
        for type in GradualTempoChangeType.allCases {
            #expect(type.defaultFactor == expected[type], "\(type)")
        }
    }

    @Test("the payload is written back: modeled fields first, the rest as read")
    func writtenBackAsRead() throws {
        let data = try MSCXEncoder.encode(Self.fixture())
        let xml = try #require(String(bytes: data, encoding: .utf8))
        for fragment in [
            "<tempoChangeType>ritardando</tempoChangeType>", "<continueText>(rit.)</continueText>",
            "<beginHookHeight>1.9</beginHookHeight>", "<tempoEasingMethod>ease-in</tempoEasingMethod>",
            "<tempoChangeFactor>1.5</tempoChangeFactor>", "<play>0</play>", "<beginText>rall.</beginText>",
        ] {
            #expect(xml.contains(fragment), "missing \(fragment)")
        }
        let rit = try #require(Self.changes(Self.fixture()).first)
        #expect(rit.encode().first("GradualTempoChange")?.children.first?.name == "tempoChangeType")
    }

    @Test("continue and end text round-trip on any line spanner")
    func continueAndEndTextOnAnyLine() throws {
        var line = Spanner(kind: .textLine, rawType: "TextLine", nextMeasuresOffset: 1, beginText: "cresc.")
        line.continueText = "(cresc.)"
        line.endText = "f"
        let payload = try #require(line.encode().first("TextLine"))
        #expect(payload.first("continueText")?.text == "(cresc.)")
        #expect(payload.first("endText")?.text == "f")
        let decoded = try Spanner.decode(line.encode())
        #expect(decoded.continueText == "(cresc.)")
        #expect(decoded.endText == "f")
    }

    @Test("stripping preserved markup clears the payload's bag")
    func strippingClearsPayloadBag() throws {
        let stripped = try Self.changes(Self.fixture().strippingPreservedMarkup())
        try #require(stripped.count == 3)
        let allEmpty = stripped.allSatisfy { $0.gradualTempoChange?.preservedMarkup.isEmpty == true }
        #expect(allEmpty)
    }
}
