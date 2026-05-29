@testable import SheetMusicCore
import Testing

struct ScoreDiagnosticTests {
    @Test func constructs_with_all_fields() {
        let d = ScoreDiagnostic(
            severity: .warning,
            code: "mscx.tremolo.unknownSubtype",
            message: "Tremolo unknown <subtype> r128",
            location: "measure 1, voice 1, Tremolo",
        )
        #expect(d.severity == .warning)
        #expect(d.code == "mscx.tremolo.unknownSubtype")
        #expect(d.message == "Tremolo unknown <subtype> r128")
        #expect(d.location == "measure 1, voice 1, Tremolo")
    }

    @Test func location_defaults_to_nil() {
        let d = ScoreDiagnostic(
            severity: .info,
            code: "mscx.test",
            message: "hello",
        )
        #expect(d.location == nil)
    }

    @Test func is_hashable_and_equatable() {
        let a = ScoreDiagnostic(severity: .warning, code: "x", message: "y")
        let b = ScoreDiagnostic(severity: .warning, code: "x", message: "y")
        let c = ScoreDiagnostic(severity: .info, code: "x", message: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
