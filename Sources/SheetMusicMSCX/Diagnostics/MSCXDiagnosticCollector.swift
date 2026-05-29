import Foundation
import SheetMusicCore

/// Collects `ScoreDiagnostic` entries during a single MSCX parse call.
/// Owned for the lifetime of one `parseWithDiagnostics(...)` invocation;
/// not intended for sharing across parses or threads.
///
/// `@unchecked Sendable`: the collector is mutated through its reference
/// during a single-threaded parse, then handed off as a snapshot via
/// `MSCXParseResult`. No concurrent access occurs in practice.
final class MSCXDiagnosticCollector: @unchecked Sendable {
    private(set) var entries: [ScoreDiagnostic] = []

    func warn(
        code: String,
        message: String,
        location: String? = nil,
    ) {
        entries.append(ScoreDiagnostic(
            severity: .warning,
            code: code,
            message: message,
            location: location,
        ))
    }

    func info(
        code: String,
        message: String,
        location: String? = nil,
    ) {
        entries.append(ScoreDiagnostic(
            severity: .info,
            code: code,
            message: message,
            location: location,
        ))
    }
}
