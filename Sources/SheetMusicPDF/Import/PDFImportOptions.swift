import Foundation

/// Non-fatal recognition issues surfaced from `PDFImporter`.
/// Currently held internal — see `PDFImporter` doc comment.
struct PDFImportDiagnostic: Sendable {
    enum Severity: Sendable { case info, warning }
    let severity: Severity
    let location: String // e.g. "page 3, system 2, measure 17"
    let message: String
    let context: String?

    init(
        severity: Severity, location: String,
        message: String, context: String? = nil
    ) {
        self.severity = severity
        self.location = location
        self.message = message
        self.context = context
    }
}

struct PDFImportOptions: Sendable {
    var preserveBreaks: Bool = true
    var useMetadataAsFallback: Bool = true
    var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    init() {}
}
