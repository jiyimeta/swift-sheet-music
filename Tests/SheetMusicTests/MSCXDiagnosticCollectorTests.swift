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
