import Foundation

/// Non-fatal recognition issues surfaced from `PDFImporter`.
public struct PDFImportDiagnostic {
    public enum Severity { case info, warning }
    public let severity: Severity
    public let location: String // e.g. "page 3, system 2, measure 17"
    public let message: String
    public let context: String?

    public init(
        severity: Severity, location: String,
        message: String, context: String? = nil,
    ) {
        self.severity = severity
        self.location = location
        self.message = message
        self.context = context
    }
}

public struct PDFImportOptions {
    public var preserveBreaks = true
    public var useMetadataAsFallback = true
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    public init() {}
}
