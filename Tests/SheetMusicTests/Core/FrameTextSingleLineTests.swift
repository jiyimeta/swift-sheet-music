@testable import SheetMusicCore
import Testing

/// `FrameText.singleLineText` — a multi-line title joined for the hosts' one-line displays.
@Suite("FrameText — singleLineText")
struct FrameTextSingleLineTests {
    private static func single(_ text: String) -> String {
        FrameText(style: .title, text: text).singleLineText
    }

    @Test("a newline between two lines becomes one space")
    func joinsWithASpace() {
        #expect(Self.single("X\narr. Y") == "X arr. Y")
    }

    @Test("a run of newlines is one space, and the ends are trimmed")
    func collapsesAndTrims() {
        #expect(Self.single("\nA\n\nB\n") == "A B")
    }

    @Test("a one-line text is unchanged")
    func oneLineUnchanged() {
        #expect(Self.single("A") == "A")
    }

    @Test("an empty text stays empty")
    func emptyStaysEmpty() {
        #expect(Self.single("").isEmpty)
    }
}
