import Foundation

/// TaskLocal stash that lets decoders find the active
/// `MSCXDiagnosticCollector` without threading it through every
/// signature. Set by `MSCXParser.parseWithDiagnostics(...)` and
/// `MSCZReader.parseWithDiagnostics(...)`; nil outside those scopes
/// (in which case decoders skip the diagnostic and behave exactly as
/// before).
enum MSCXParserContext {
    @TaskLocal static var collector: MSCXDiagnosticCollector?
}
