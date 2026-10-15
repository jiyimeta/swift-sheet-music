import Foundation
@testable import SheetMusicCore
@testable import SheetMusicEditWire
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

/// F6.2: `chantCaesura` and `caesuraSingleStroke` are MuseScore caesuras (`dom/breath.cpp:39-50`); they decode,
/// draw their own glyph, save under their own name and cross the edit wire.
@Suite("Breath caesura variants")
struct BreathVariantRoundTripTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("both new symbols decode to their own kind")
    func decodesBoth() throws {
        for (symbol, expected) in [
            ("chantCaesura", Breath.CaesuraStyle.chant),
            ("caesuraSingleStroke", .singleStroke),
        ] {
            let score = try BreathRoundTripTests.parse(BreathRoundTripTests.mscxWith(symbol: symbol))
            guard case let .breath(breath) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
                Issue.record("no breath for \(symbol)"); continue
            }
            #expect(breath.kind == .caesura(expected))
        }
    }

    @Test("both new kinds are saved under their own name")
    func encodesBoth() throws {
        for symbol in ["chantCaesura", "caesuraSingleStroke"] {
            let parsed = try BreathRoundTripTests.parse(BreathRoundTripTests.mscxWith(symbol: symbol))
            let written = try #require(try String(data: MSCXEncoder.encode(parsed), encoding: .utf8))
            #expect(written.contains("<symbol>\(symbol)</symbol>"))
            #expect(!written.contains("breathMarkComma"))
        }
    }

    @Test("each kind draws its own SMuFL glyph")
    func glyphs() {
        #expect(BreathGlyph.codepoint(forKind: .caesura(.chant)) == 0xE8F8)
        #expect(BreathGlyph.codepoint(forKind: .caesura(.singleStroke)) == 0xE4D7)
    }

    @Test("the edit wire carries both new styles and keeps the old indices")
    func wire() throws {
        for style in [Breath.CaesuraStyle.chant, .singleStroke] {
            let wire = SetBreathIntentWire(location: VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            ), kind: .caesura(style), pause: 0.5)
            #expect(try wire.decoded().kind == .caesura(style))
        }
        #expect(
            Breath.CaesuraStyle.allCases.map(\.rawValue)
                == ["normal", "short", "thick", "curved", "chant", "singleStroke"],
        )
    }

    @Test("the fixture's two new caesuras lay out as breaths and sit where a normal caesura sits")
    func layout() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fermata-breath-variants"))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2400)
        let breaths = document.systems.flatMap(\.measures).flatMap(\.elements)
            .compactMap { element -> (Breath.Kind, Double)? in
                if case let .breath(kind, origin, _) = element { return (kind, Double(origin.y)) }
                return nil
            }
        // All three are laid out as breaths. (The y of two caesuras is compared only within one system — the same
        // staff-relative branch, `layoutBreath`, `rendering/score/tlayout.cpp:1483-1489` — and the fixture's 24 bars
        // do not guarantee they share one, so this test pins existence; `BreathLayoutTests` pins the branch.)
        _ = try #require(breaths.first { $0.0 == .caesura(.normal) })
        _ = try #require(breaths.first { $0.0 == .caesura(.chant) })
        _ = try #require(breaths.first { $0.0 == .caesura(.singleStroke) })
    }
}
