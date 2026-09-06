@testable import SheetMusicCore
import Testing

struct ElementOffsetTests {
    @Test func zeroInitializerOffsetsRemainAbsent() {
        #expect(RehearsalMark(text: "A").elementProperties.offset == nil)
        #expect(Harmony(name: "C").elementProperties.offset == nil)
        #expect(Tempo(beatsPerSecond: 2).elementProperties.offset == nil)
        #expect(Swing().elementProperties.offset == nil)
        #expect(InstrumentChange(text: "change").elementProperties.offset == nil)
        #expect(StaffText(text: "text").elementProperties.offset == nil)
    }

    @Test func rehearsalMarkUsesSharedOffset() {
        var value = RehearsalMark(text: "A", offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    @Test func harmonyUsesSharedOffset() {
        var value = Harmony(name: "C", offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    @Test func tempoUsesSharedOffset() {
        var value = Tempo(beatsPerSecond: 2, offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    @Test func swingUsesSharedOffset() {
        var value = Swing(offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    @Test func instrumentChangeUsesSharedOffset() {
        var value = InstrumentChange(text: "change", offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    @Test func staffTextUsesSharedOffset() {
        var value = StaffText(text: "text", offsetX: 1.25, offsetY: -2.5)
        verifyOffsetSugar(&value, elementProperties: \.elementProperties, offsetX: \.offsetX, offsetY: \.offsetY)
    }

    private func verifyOffsetSugar<Value>(
        _ value: inout Value,
        elementProperties: WritableKeyPath<Value, ElementProperties>,
        offsetX: WritableKeyPath<Value, Double>,
        offsetY: WritableKeyPath<Value, Double>,
    ) {
        #expect(value[keyPath: elementProperties].offset == ScoreOffset(x: 1.25, y: -2.5))

        value[keyPath: elementProperties].offset = ScoreOffset(x: 3.75, y: -4.5)
        #expect(value[keyPath: offsetX] == 3.75)
        #expect(value[keyPath: offsetY] == -4.5)

        value[keyPath: elementProperties].offset = nil
        #expect(value[keyPath: offsetX] == 0)
        #expect(value[keyPath: offsetY] == 0)

        value[keyPath: offsetX] = 5.25
        #expect(value[keyPath: elementProperties].offset == ScoreOffset(x: 5.25, y: 0))

        value[keyPath: offsetY] = -6.75
        #expect(value[keyPath: elementProperties].offset == ScoreOffset(x: 5.25, y: -6.75))

        value[keyPath: elementProperties].offset = nil
        value[keyPath: offsetX] = 0
        #expect(value[keyPath: elementProperties].offset == ScoreOffset(x: 0, y: 0))

        value[keyPath: elementProperties].offset = nil
        value[keyPath: offsetY] = -7.25
        #expect(value[keyPath: elementProperties].offset == ScoreOffset(x: 0, y: -7.25))
    }
}
