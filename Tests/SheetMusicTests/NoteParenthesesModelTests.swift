@testable import SheetMusicCore
import Testing

struct NoteParenthesesModelTests {
    @Test func tokenRoundTripForAllCases() {
        #expect(NoteParentheses(mscxToken: "none") == .none)
        #expect(NoteParentheses(mscxToken: "left") == .left)
        #expect(NoteParentheses(mscxToken: "right") == .right)
        #expect(NoteParentheses(mscxToken: "both") == .both)
        #expect(NoteParentheses(mscxToken: "garbage") == .none)
        #expect(NoteParentheses.none.mscxToken == "none")
        #expect(NoteParentheses.left.mscxToken == "left")
        #expect(NoteParentheses.right.mscxToken == "right")
        #expect(NoteParentheses.both.mscxToken == "both")
    }

    @Test func hasLeftHasRight() {
        #expect(NoteParentheses.both.hasLeft && NoteParentheses.both.hasRight)
        #expect(NoteParentheses.left.hasLeft && !NoteParentheses.left.hasRight)
        #expect(!NoteParentheses.right.hasLeft && NoteParentheses.right.hasRight)
        #expect(!NoteParentheses.none.hasLeft && !NoteParentheses.none.hasRight)
    }

    @Test func noteDefaultsToNoneAndCarriesValue() {
        #expect(Note(pitch: 60, tpc: 14).parentheses == .none)
        #expect(Note(pitch: 60, tpc: 14, parentheses: .both).parentheses == .both)
    }
}
