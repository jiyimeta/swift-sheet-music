import Foundation
@testable import SheetMusicCore
import Testing

struct ElementPropertiesTests {
    @Test func defaultIsVisible() {
        #expect(ElementProperties.default.visible == true)
        #expect(ElementProperties().visible == true)
    }

    @Test func initStoresVisible() {
        #expect(ElementProperties(visible: false).visible == false)
    }

    @Test func equatable() {
        #expect(ElementProperties(visible: true) == ElementProperties())
        #expect(ElementProperties(visible: false) != ElementProperties())
    }

    @Test func colorDefaultsToNil() {
        #expect(ElementProperties.default.color == nil)
        #expect(ElementProperties().color == nil)
    }

    @Test func initStoresColor() {
        let red = ScoreColor(red: 255, green: 0, blue: 0)
        #expect(ElementProperties(color: red).color == red)
    }

    @Test func colorParticipatesInEquality() {
        let red = ScoreColor(red: 255, green: 0, blue: 0)
        let blue = ScoreColor(red: 0, green: 0, blue: 255)
        let redProps = ElementProperties(color: red)
        #expect(redProps != ElementProperties())
        #expect(redProps != ElementProperties(color: blue))
        #expect(redProps == ElementProperties(color: red))
    }

    @Test func colorRoundTripsThroughCodable() throws {
        let red = ScoreColor(red: 255, green: 0, blue: 0, alpha: 200)
        let props = ElementProperties(visible: false, color: red)
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(
            ElementProperties.self, from: data,
        )
        #expect(decoded == props)
    }
}
