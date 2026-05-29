import Foundation
#if canImport(os)
    import os
#endif

/// Emit a parser warning to both the active `MSCXDiagnosticCollector`
/// (when one is in scope) and `mscxDecoderLogger` (on platforms where
/// `os.Logger` is available). Used by decoders to surface anomalies
/// that don't warrant aborting the parse.
///
/// When called outside a `parseWithDiagnostics(...)` scope the
/// collector arm is a no-op; the `Logger` arm still runs so existing
/// console output is unchanged.
func mscxDecoderWarn(
    code: String,
    message: String,
    location: String? = nil,
) {
    #if canImport(os)
        let locationSuffix = location.map { " (\($0))" } ?? ""
        mscxDecoderLogger.warning(
            "\(code, privacy: .public): \(message, privacy: .public)\(locationSuffix, privacy: .public)",
        )
    #endif
    MSCXParserContext.collector?.warn(
        code: code, message: message, location: location,
    )
}
