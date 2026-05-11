@testable import SheetMusicCore
import Testing

struct BracketItemTests {
    @Test func defaultColumnIsZero() {
        let item = BracketItem(type: .brace, span: 2)
        #expect(item.column == 0)
        #expect(item.visible == true)
    }

    @Test func spanLessThanOneIsClamped() {
        let item = BracketItem(type: .normal, span: 0)
        #expect(item.span == 1)

        let neg = BracketItem(type: .normal, span: -3)
        #expect(neg.span == 1)
    }

    @Test func negativeColumnIsClamped() {
        let item = BracketItem(type: .square, span: 1, column: -2)
        #expect(item.column == 0)
    }

    @Test func bracketTypeRawValuesMatchMSCX() {
        // MuseScore's `BracketType` enum raw values used in MSCX
        // serialization (engraving/dom/bracket.h).
        #expect(BracketType.normal.rawValue == 0)
        #expect(BracketType.brace.rawValue == 1)
        #expect(BracketType.square.rawValue == 2)
        #expect(BracketType.line.rawValue == 3)
        #expect(BracketType.noBracket.rawValue == -1)
    }

    @Test func staffBracketsDefaultsToEmpty() {
        let s = Staff()
        #expect(s.brackets.isEmpty)
    }

    @Test func staffInitAcceptsBrackets() {
        let s = Staff(brackets: [
            BracketItem(type: .brace, span: 2),
        ])
        #expect(s.brackets.count == 1)
        #expect(s.brackets[0].type == .brace)
    }
}
