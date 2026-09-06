import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<StaffTypeChange>` and `<StaffState>` round-trip through preserved markup
/// without either being modeled.
///
/// The parity doc listed both under §4.5 "staff / part structure" as though
/// they needed a staff time axis before they could survive a save. They do not:
/// neither is a `<Staff>` sibling. `<StaffTypeChange>` is a `<Measure>` child
/// (`rw/read460/tread.cpp:2291`, reached from `measureread.cpp:189`'s
/// `readProperties(static_cast<MeasureBase*>(measure), …)`) and `<StaffState>`
/// is a voice-stream annotation (`measureread.cpp:501`, in the same branch as
/// `Sticking`, `Capo`, `StringTunings`, and `InstrumentChange`). Neither tag is
/// in any decoder's consumed set, so both land in a bag and come back.
///
/// **This suite is what makes that a measurement rather than a deduction.**
/// Before `own/staff-elements.mscx` existed, no committed fixture carried
/// either tag, so the preservation gate had never once exercised the claim —
/// and that gate `continue`s past a fixture it cannot parse, so its green would
/// have said nothing either way.
@Suite("Staff structure elements round-trip")
struct StaffStructureRoundTripTests {
    private func encodedFixture() throws -> XMLTreeNode {
        let source = try MSCXFixtureLoader.mscxData("staff-elements")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        return try XMLTreeParser.parse(encoded)
    }

    /// Proves the fixture decodes at all, and that the elements reach the model
    /// as preserved markup rather than being dropped by the decoder.
    @Test func bothElementsSurviveDecodingIntoTheirBags() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("staff-elements"))
        let measures = score.parts[0].staves[0].measures
        #expect(measures.count == 3)

        let typeChange = measures[1].preservedMarkup.first { $0.name == "StaffTypeChange" }
        let staffType = try #require(typeChange?.children.first { $0.name == "StaffType" })
        #expect(staffType.attributes["group"] == "tab")
        #expect(staffType.children.first { $0.name == "lines" }?.text == "6")

        let staffStates = measures[2].voices[0].elements.compactMap { element -> PreservedXML? in
            guard case let .preserved(markup) = element, markup.name == "StaffState" else {
                return nil
            }
            return markup
        }
        #expect(staffStates.count == 1)
        #expect(staffStates.first?.children.first { $0.name == "subtype" }?.text == "1")
    }

    @Test func staffTypeChangeIsWrittenBackUnderItsMeasure() throws {
        let root = try encodedFixture()
        let measures = try #require(root.first("Score")?.first("Staff")).all("Measure")
        #expect(measures.count == 3)
        let typeChange = try #require(measures[1].first("StaffTypeChange"))
        let staffType = try #require(typeChange.first("StaffType"))
        #expect(staffType.attributes["group"] == "tab")
        #expect(staffType.first("lines")?.text == "6")
        #expect(staffType.first("lineDistance")?.text == "1.5")
    }

    /// A voice-stream annotation has to come back at its position in the
    /// element stream, not appended at the end of the bar — that is what
    /// `VoiceElement.preserved` exists for.
    @Test func staffStateIsWrittenBackInsideItsVoice() throws {
        let root = try encodedFixture()
        let measures = try #require(root.first("Score")?.first("Staff")).all("Measure")
        let voice = try #require(measures[2].first("voice"))
        let names = voice.children.map(\.name)
        let stateIndex = try #require(names.firstIndex(of: "StaffState"))
        let chordIndex = try #require(names.firstIndex(of: "Chord"))
        #expect(stateIndex < chordIndex)
        #expect(voice.first("StaffState")?.first("subtype")?.text == "1")
    }

    @Test func neitherElementIsModeled() throws {
        // If a later slice models one of these, this expectation is the thing
        // that should be deleted along with the preserved-markup claim in the
        // parity doc's §4.5 — not quietly left passing against a bag that no
        // longer fills.
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("staff-elements"))
        let stripped = score.strippingPreservedMarkup()
        let encoded = try MSCXEncoder.encode(stripped)
        let root = try XMLTreeParser.parse(encoded)
        let staff = try #require(root.first("Score")?.first("Staff"))
        // Bound to locals because SwiftLint reads a bare `first(…) == nil` as
        // the `first(where:)` overload and asks for `contains`.
        let typeChanges = staff.all("Measure").compactMap { $0.first("StaffTypeChange") }
        let staffStates = staff.all("Measure").compactMap { $0.first("voice")?.first("StaffState") }
        #expect(typeChanges.isEmpty)
        #expect(staffStates.isEmpty)
    }
}
