@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct MSCXDiagnosticCollectorTests {
    @Test func warn_appends_warning_entry() {
        let c = MSCXDiagnosticCollector()
        c.warn(code: "mscx.test", message: "hello")
        #expect(c.entries.count == 1)
        #expect(c.entries[0].severity == .warning)
        #expect(c.entries[0].code == "mscx.test")
        #expect(c.entries[0].message == "hello")
        #expect(c.entries[0].location == nil)
    }

    @Test func info_appends_info_entry_with_location() {
        let c = MSCXDiagnosticCollector()
        c.info(code: "mscx.score.ms2", message: "MS2 path", location: "Score")
        #expect(c.entries.count == 1)
        #expect(c.entries[0].severity == .info)
        #expect(c.entries[0].location == "Score")
    }

    @Test func task_local_starts_nil() {
        #expect(MSCXParserContext.collector == nil)
    }

    @Test func task_local_scopes_collector() {
        let c = MSCXDiagnosticCollector()
        MSCXParserContext.$collector.withValue(c) {
            #expect(MSCXParserContext.collector === c)
        }
        #expect(MSCXParserContext.collector == nil)
    }
}

struct MSCXDecoderWarnTests {
    @Test func warn_helper_appends_to_active_collector() {
        let c = MSCXDiagnosticCollector()
        MSCXParserContext.$collector.withValue(c) {
            mscxDecoderWarn(
                code: "mscx.test",
                message: "hi",
                location: "x",
            )
        }
        #expect(c.entries.count == 1)
        #expect(c.entries[0].code == "mscx.test")
        #expect(c.entries[0].location == "x")
    }

    @Test func warn_helper_is_no_op_without_active_collector() {
        // Must not crash when no collector is in scope. Outside withValue,
        // `MSCXParserContext.collector` is nil.
        mscxDecoderWarn(code: "mscx.test", message: "hi")
        // (No assertion needed beyond the call not throwing / crashing.)
    }
}

struct MSCXParseResultTests {
    @Test func has_score_and_diagnostics() {
        // Use the smallest possible bundled fixture to avoid pulling in
        // additional XML parsing here — construct directly.
        // We can't easily build a Score in isolation, so just verify
        // the wrapper compiles and exposes the two fields. Use Mirror
        // instead of constructing a Score by hand.
        let result = MSCXParseResult.empty()
        #expect(result.diagnostics.isEmpty)
        // `score` is non-optional; if accessing compiles, the contract
        // is satisfied for this smoke check.
        _ = result.score
    }
}

extension MSCXParseResult {
    /// Test helper that fabricates an empty Score so we can construct
    /// an MSCXParseResult without going through a real parse.
    fileprivate static func empty() -> MSCXParseResult {
        MSCXParseResult(
            score: Score(division: 480, parts: []),
            diagnostics: [],
        )
    }
}
