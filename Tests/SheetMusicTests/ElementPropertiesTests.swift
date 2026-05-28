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
}
