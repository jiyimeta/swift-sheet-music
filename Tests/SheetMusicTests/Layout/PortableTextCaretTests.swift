import SheetMusicLayout
import Testing

@Suite("PortableTextCaret")
struct PortableTextCaretTests {
    @Test func fallbackRepeatsOffsetsInsideGraphemes() {
        let provider = StubFontMetricsProvider()
        let font = LayoutFont(face: "", pointSize: 20)
        let offsets = provider.caretOffsets(text: "😀e\u{301}", font: font)
        #expect(offsets.count == 5)
        #expect(offsets[0] == offsets[1])
        #expect(offsets[2] == offsets[3])
        #expect(offsets[4] == provider.typographicWidth(text: "😀e\u{301}", font: font))
        #expect(provider.characterIndex(forOffset: -10, text: "😀e\u{301}", font: font) == 0)
        #expect(provider.characterIndex(forOffset: 1000, text: "😀e\u{301}", font: font) == 4)
    }
}
