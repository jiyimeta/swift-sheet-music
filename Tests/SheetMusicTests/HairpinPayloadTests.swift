@testable import SheetMusicCore
import Testing

struct HairpinPayloadTests {
    @Test func defaultSpannerHasNilHairpin() {
        let s = Spanner(kind: .hairpin, rawType: "HairPin")
        #expect(s.hairpin == nil)
    }

    @Test func payloadEqualityRespectsAllFields() {
        let a = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        let b = Spanner.HairpinPayload(
            subtype: .crescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        let c = Spanner.HairpinPayload(
            subtype: .decrescendo,
            veloChange: 20,
            veloChangeMethod: .normal,
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test func subtypeRawValuesMatchMuseScore() {
        #expect(Spanner.HairpinPayload.Subtype.crescendo.rawValue == 0)
        #expect(Spanner.HairpinPayload.Subtype.decrescendo.rawValue == 1)
    }

    @Test func veloChangeMethodFromXMLString() {
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "normal") == .normal)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in") == .easeIn)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-out") == .easeOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "ease-in-out") == .easeInOut)
        #expect(Spanner.HairpinPayload.VeloChangeMethod(rawValue: "exponential") == .exponential)
    }
}
