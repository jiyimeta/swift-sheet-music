@testable import SheetMusicCore
import Testing

/// MuseScore's text format state machine (`TextBase::createBlocks` / `prepareFormat`,
/// `engraving/dom/textbase.cpp:1659-1818`), read through both shapes MuseScore stores formatted text in.
@Suite("RichText")
struct RichTextTests {
    private typealias Item = PreservedTextMarkup.ContentItem

    private static func element(_ name: String, attributes: [String: String] = [:], _ content: Item...) -> Item {
        .element(PreservedTextMarkup.Element(name: name, attributes: attributes, content: content))
    }

    private static let plain = RichTextFormat()
    private static let bold = RichTextFormat(bold: true)
    private static let unbold = RichTextFormat(bold: false)

    // MARK: - The <text> element tree

    @Test("a <br/> starts a line, and the plain text keeps it as a line break")
    func lineBreak() {
        let rich = RichText(content: [.characters("poco a poco"), Self.element("br"), .characters("cresc.")])
        #expect(rich.lines == [[.text("poco a poco", Self.plain)], [.text("cresc.", Self.plain)]])
        #expect(rich.plainText == "poco a poco\ncresc.")
    }

    @Test("formatting does not reorder text: <b>Solo</b> ad lib.")
    func boldFirst() {
        let rich = RichText(content: [Self.element("b", .characters("Solo")), .characters(" ad lib.")])
        #expect(rich.lines == [[.text("Solo", Self.bold), .text(" ad lib.", Self.unbold)]])
        #expect(rich.plainText == "Solo ad lib.")
    }

    @Test("a <sym> is a symbol run and contributes nothing to the plain text")
    func symbol() {
        let rich = RichText(content: [.characters("senza "), Self.element("sym", .characters("keyboardPedalPed"))])
        #expect(rich.lines == [[.text("senza ", Self.plain), .symbol(name: "keyboardPedalPed", Self.plain)]])
        #expect(rich.plainText == "senza ")
    }

    @Test("a closing tag turns its state off even inside an outer one, as prepareFormat does")
    func closingTagIsAStateChange() {
        let rich = RichText(content: [
            Self.element("b", .characters("a"), Self.element("b", .characters("b")), .characters("c")),
        ])
        #expect(rich.lines == [[.text("ab", Self.bold), .text("c", Self.unbold)]])
    }

    @Test("MuseScore's lineBreakTest: <b><i><s><font size=\"17\"/>aaa<br/><br/>bbb</s></i></b>")
    func museScoreLineBreakCase() {
        let inner = Self.element(
            "s", Self.element("font", attributes: ["size": "17"]),
            .characters("aaa"), Self.element("br"), Self.element("br"), .characters("bbb"),
        )
        let rich = RichText(content: [Self.element("b", Self.element("i", inner))])
        let format = RichTextFormat(bold: true, italic: true, strike: true, size: 17)
        #expect(rich.lines == [[.text("aaa", format)], [], [.text("bbb", format)]])
        #expect(rich.plainText == "aaa\n\nbbb")
    }

    @Test("a <font> setting outlives the element it was written in")
    func fontIsAState() {
        let rich = RichText(content: [
            Self.element("b", Self.element("font", attributes: ["size": "14", "face": "Edwin"]), .characters("x")),
            .characters("y"),
        ])
        #expect(rich.lines == [[
            .text("x", RichTextFormat(bold: true, face: "Edwin", size: 14)),
            .text("y", RichTextFormat(bold: false, face: "Edwin", size: 14)),
        ]])
    }

    @Test("<sub> and <sup> set the vertical alignment until they close")
    func scripts() {
        let rich = RichText(content: [
            .characters("H"), Self.element("sub", .characters("2")), .characters("O"),
            Self.element("sup", .characters("+")),
        ])
        #expect(rich.lines == [[
            .text("H", Self.plain), .text("2", RichTextFormat(verticalAlign: .subScript)),
            .text("O", Self.plain), .text("+", RichTextFormat(verticalAlign: .superScript)),
        ]])
    }

    @Test("an unknown tag is transparent")
    func unknownTag() {
        let rich = RichText(content: [Self.element("span", .characters("a")), .characters("b")])
        #expect(rich.lines == [[.text("ab", Self.plain)]])
    }

    @Test("character data that is only whitespace is dropped, as MuseScore's reader drops it")
    func whitespaceOnlyData() {
        let rich = RichText(content: [.characters("\n  "), Self.element("b", .characters("X")), .characters("\n")])
        #expect(rich.lines == [[.text("X", Self.bold)]])
        #expect(rich.plainText == "X")
    }

    @Test("a literal line feed starts a line, as createBlocks treats it")
    func literalLineFeed() {
        let rich = RichText(content: [.characters("a\nb"), Self.element("b", .characters("c"))])
        #expect(rich.lines == [[.text("a", Self.plain)], [.text("b", Self.plain), .text("c", Self.bold)]])
    }

    @Test("leading, trailing and doubled line breaks are lines of their own, in the plain text too")
    func emptyLines() {
        let rich = RichText(content: [
            Self.element("br"), .characters("a"), Self.element("br"), Self.element("br"),
        ])
        #expect(rich.lines.count == 4)
        #expect(rich.plainText == "\na\n\n")
        #expect(rich.plainText.split(separator: "\n", omittingEmptySubsequences: false).count == rich.lines.count)
    }

    @Test("no content is one empty line")
    func emptyContent() {
        #expect(RichText(content: []).lines == [[]])
        #expect(RichText(lines: []).lines == [[]])
    }

    // MARK: - xml text held as a string

    @Test("a <beginText> string's tags are read as tags")
    func xmlTextTags() {
        #expect(RichText(xmlText: "<sym>keyboardPedalPed</sym>").lines == [
            [.symbol(name: "keyboardPedalPed", Self.plain)],
        ])
        #expect(RichText(xmlText: "<font size=\"12\"/>VII").lines == [[.text("VII", RichTextFormat(size: 12))]])
        #expect(RichText(xmlText: "<b>rit.</b> poco").lines == [
            [.text("rit.", Self.bold), .text(" poco", Self.unbold)],
        ])
        #expect(RichText(xmlText: "a<br/>b").plainText == "a\nb")
    }

    @Test("entities decode; a stray & or < stays literal, so a label typed as text draws as typed")
    func xmlTextLiterals() {
        #expect(RichText(xmlText: "Tom &amp; Jerry").plainText == "Tom & Jerry")
        #expect(RichText(xmlText: "x &lt;y&gt;").plainText == "x <y>")
        #expect(RichText(xmlText: "1 & 2").plainText == "1 & 2")
        #expect(RichText(xmlText: "a < b").plainText == "a < b")
        #expect(RichText(xmlText: "a < b <i>c</i>").lines == [
            [.text("a < b ", Self.plain), .text("c", RichTextFormat(italic: true))],
        ])
    }

    @Test("<u> sets underline and </u> clears it")
    func underline() {
        #expect(RichText(xmlText: "<u>a</u>b").lines == [
            [.text("a", RichTextFormat(underline: true)), .text("b", RichTextFormat(underline: false))],
        ])
    }

    @Test("</i> and </s> clear their state")
    func italicAndStrikeClear() {
        #expect(RichText(xmlText: "<i>a</i>b<s>c</s>d").lines == [[
            .text("a", RichTextFormat(italic: true)),
            .text("b", RichTextFormat(italic: false)),
            .text("c", RichTextFormat(italic: false, strike: true)),
            .text("d", RichTextFormat(italic: false, strike: false)),
        ]])
    }

    @Test("</sup> returns to the normal alignment for the text after it")
    func superscriptCloses() {
        #expect(RichText(xmlText: "x<sup>2</sup>y").lines == [[
            .text("x", Self.plain), .text("2", RichTextFormat(verticalAlign: .superScript)), .text("y", Self.plain),
        ]])
    }

    @Test("&quot;, &gt; and &apos; decode in xml text")
    func quoteEntities() {
        #expect(RichText(xmlText: "say &quot;hi&quot; &gt; &apos;x&apos;").plainText == "say \"hi\" > 'x'")
    }

    // MARK: - Whitespace, line ends and self-closing tags

    @Test("only ASCII space, tab, CR and LF make character data droppable; NBSP and U+3000 are kept")
    func unicodeWhitespaceIsText() {
        #expect(RichText(content: [.characters("\u{A0}")]).lines == [[.text("\u{A0}", Self.plain)]])
        #expect(RichText(content: [.characters("\u{3000}")]).lines == [[.text("\u{3000}", Self.plain)]])
        let crlf = RichText(content: [.characters("\r\n\t "), Self.element("b", .characters("X"))])
        #expect(crlf.lines == [[.text("X", Self.bold)]])
    }

    @Test("CRLF and a lone CR are one line break, in xml text and in the element tree")
    func carriageReturns() {
        let twoLines: [[RichTextRun]] = [[.text("a", Self.plain)], [.text("b", Self.plain)]]
        #expect(RichText(xmlText: "a\r\nb").lines == twoLines)
        #expect(RichText(xmlText: "a\rb").lines == twoLines)
        #expect(RichText(content: [.characters("a\r\nb")]).lines == twoLines)
    }

    @Test("a self-closing <i/> in <b> is a no-op: the text stays bold and italic stays unset (element tree)")
    func selfClosingFormatTagTree() {
        let rich = RichText(content: [
            Self.element("b", .characters("x"), Self.element("i"), .characters("y")),
        ])
        #expect(rich.lines == [[.text("xy", Self.bold)]])
    }

    @Test("a self-closing <i/> in <b> is a no-op: the text stays bold and italic stays unset (xml text)")
    func selfClosingFormatTagXmlText() {
        #expect(RichText(xmlText: "<b>x<i/>y</b>").lines == [[.text("xy", Self.bold)]])
    }

    @Test("an empty or self-closing <sym> emits nothing")
    func emptySymbol() {
        #expect(RichText(xmlText: "a<sym/>b").lines == [[.text("ab", Self.plain)]])
        #expect(RichText(xmlText: "a<sym></sym>b").lines == [[.text("ab", Self.plain)]])
        #expect(RichText(content: [.characters("a"), Self.element("sym")]).lines == [[.text("a", Self.plain)]])
    }

    // MARK: - Malformed xml text

    @Test("an unclosed tag at the end stays literal")
    func unclosedTag() {
        #expect(RichText(xmlText: "a <b").lines == [[.text("a <b", Self.plain)]])
    }

    @Test("an & with no ; stays literal")
    func ampersandWithoutSemicolon() {
        #expect(RichText(xmlText: "a & b").lines == [[.text("a & b", Self.plain)]])
    }

    @Test("an empty tag <> is transparent and leaves no characters")
    func emptyTag() {
        #expect(RichText(xmlText: "<>").lines == [[]])
    }

    @Test("an unterminated <sym>name has no closing tag, so it emits no run")
    func unterminatedSymbol() {
        #expect(RichText(xmlText: "<sym>name").lines == [[]])
    }

    // MARK: - Currency

    @Test("markup reads as rich text only while it still describes the text")
    func currency() {
        let markup = PreservedTextMarkup(
            content: [Self.element("b", .characters("Solo")), .characters(" ad lib.")],
            derivedText: "Solo ad lib.",
        )
        #expect(markup.richText(ifCurrentFor: "Solo ad lib.")?.plainText == "Solo ad lib.")
        #expect(markup.richText(ifCurrentFor: "edited") == nil)
    }
}
