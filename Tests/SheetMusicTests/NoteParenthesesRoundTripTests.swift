import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesRoundTripTests {
    private func roundTrip(_ parens: NoteParentheses, version: MSCXVersion) throws -> NoteParentheses {
        let note = Note(pitch: 60, tpc: 14, parentheses: parens)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: version))
        return try Note.decode(encoded).parentheses
    }

    @Test func v4RoundTripsAllModes() throws {
        #expect(try roundTrip(.both, version: .v4) == .both)
        #expect(try roundTrip(.left, version: .v4) == .left)
        #expect(try roundTrip(.right, version: .v4) == .right)
        #expect(try roundTrip(.none, version: .v4) == .none)
    }

    @Test func v3RoundTripsViaSymbols() throws {
        #expect(try roundTrip(.both, version: .v3) == .both)
        #expect(try roundTrip(.left, version: .v3) == .left)
        #expect(try roundTrip(.right, version: .v3) == .right)
        #expect(try roundTrip(.none, version: .v3) == .none)
    }

    @Test func v4EmitsParenthesesElement() {
        let note = Note(pitch: 60, tpc: 14, parentheses: .both)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v4))
        #expect(encoded.first("parentheses")?.text == "both")
    }

    @Test func v3EmitsSymbolElements() {
        let note = Note(pitch: 60, tpc: 14, parentheses: .both)
        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v3))
        let symNames = encoded.all("Symbol").compactMap { $0.first("name")?.text }
        #expect(symNames.contains("noteheadParenthesisLeft"))
        #expect(symNames.contains("noteheadParenthesisRight"))
    }
}
