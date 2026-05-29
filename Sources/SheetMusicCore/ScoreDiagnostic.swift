import Foundation

/// Non-fatal anomaly observed while parsing a score. Collected by
/// `MSCXParser.parseWithDiagnostics(...)` / `MSCZReader.parseWithDiagnostics(...)`
/// instead of being thrown, so callers can recover partial data and
/// surface a warning UI.
public struct ScoreDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable {
        /// Recoverable: the offending element was dropped or defaulted.
        case warning
        /// Notable but expected (e.g. MS2 compatibility path).
        case info
    }

    public let severity: Severity
    /// Stable, machine-readable identifier. Dotted namespace under
    /// `mscx.<element>.<reason>` — e.g. `"mscx.tremolo.unknownSubtype"`.
    /// Useful for downstream filtering / suppression / localisation.
    public let code: String
    /// Human-readable English message. Localisation is the caller's job.
    public let message: String
    /// Best-effort location string — e.g. `"measure 12, voice 1, Tremolo"`.
    /// `nil` when the producer cannot derive a location cheaply.
    public let location: String?

    public init(
        severity: Severity,
        code: String,
        message: String,
        location: String? = nil,
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
    }
}
