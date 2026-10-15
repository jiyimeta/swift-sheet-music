@testable import SheetMusicCore
import Testing

/// The font overrides an annotation keeps as unmodeled children are readable as `TextProperties` — and only those.
@Suite("Text properties from preserved children")
struct TextPropertiesPreservedTests {
    private static func child(_ name: String, _ text: String) -> PreservedXML {
        PreservedXML(name: name, text: text)
    }

    @Test func faceSizeAndStyleAreRead() {
        let props = TextProperties(fontChildrenOf: [
            Self.child("face", "Campania"), Self.child("size", "14"), Self.child("bold", "1"),
            Self.child("italic", "0"),
        ])
        #expect(props.face == "Campania")
        #expect(props.size == 14)
        #expect(props.style == [.bold])
        #expect(props.frameType == nil)
    }

    @Test func nothingElseIsRead() {
        let props = TextProperties(fontChildrenOf: [
            Self.child("style", "user_1"), Self.child("align", "center"), Self.child("musicSymbolSize", "18"),
        ])
        #expect(props.isEmpty)
    }

    @Test func noFlagMeansNoOpinion() {
        #expect(TextProperties(fontChildrenOf: [Self.child("size", "9")]).style == nil)
        #expect(TextProperties(fontChildrenOf: []).isEmpty)
    }

    @Test func carriersExposeTheirOwn() {
        var expression = ExpressionText(text: "dolce")
        expression.preservedMarkup = [Self.child("size", "12")]
        #expect(expression.fontOverrides.size == 12)
        var sticking = Sticking(text: "R")
        sticking.preservedMarkup = [Self.child("italic", "1")]
        #expect(sticking.fontOverrides.style == [.italic])
    }
}
