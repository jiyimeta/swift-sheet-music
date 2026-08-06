import Foundation
@testable import SheetMusicCore
import Testing

@Suite("InstrumentChange model")
struct InstrumentChangeModelTests {
    @Test("defaults: visible, no colour, not user-initialized, no instrument")
    func defaults() {
        let change = InstrumentChange(text: "アコーディオン に")
        #expect(change.text == "アコーディオン に")
        #expect(change.instrument == nil)
        #expect(change.isUserInitialized == false)
        #expect(change.visible == true)
        #expect(change.color == nil)
        #expect(change.offsetX == 0)
        #expect(change.offsetY == 0)
    }

    @Test("colour and visible are sugar over elementProperties")
    func sugarWritesThrough() {
        var change = InstrumentChange(text: "to Accordion")
        change.color = ScoreColor(red: 10, green: 20, blue: 30)
        change.visible = false
        #expect(change.elementProperties.color == ScoreColor(red: 10, green: 20, blue: 30))
        #expect(change.elementProperties.visible == false)
    }

    @Test("styleType is the dedicated instrumentChange row")
    func styleType() {
        #expect(InstrumentChange(text: "x").styleType == .instrumentChange)
    }

    @Test("SystemElement carries the change and stays Equatable")
    func systemElementCase() {
        let a = SystemElement.instrumentChange(InstrumentChange(text: "x"))
        let b = SystemElement.instrumentChange(InstrumentChange(text: "x"))
        let c = SystemElement.instrumentChange(InstrumentChange(text: "y"))
        #expect(a == b)
        #expect(a != c)
    }
}
