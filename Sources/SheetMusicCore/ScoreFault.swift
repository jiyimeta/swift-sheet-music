import SheetMusicFoundation

/// The non-recoverable counterpart of `ScoreDiagnostic`: the structured
/// payload of `SheetMusicError.malformedScore` / `.corruptedContainer`.
/// Same shape on purpose: a fatal fault and a collected diagnostic are the
/// same producer speaking to the same consumer, and localization is keyed
/// the same way by `code`, never by matching the English `message`.
public struct ScoreFault: Sendable, Hashable {
    /// Stable, machine-readable identifier. Dotted namespace, no spaces,
    /// no interpolation, e.g. `"mscx.timeSig.missingSigN"`, `"zip.corrupted"`,
    /// `"midi.smf.truncated"`. The first segment names the producing format.
    public let code: String
    /// Human-readable English message for logs and tests. May interpolate
    /// offsets, entry names, or element names. Never UI copy.
    public let message: String
    /// Best-effort location: a ZIP entry path, an XML element context, or a
    /// byte offset. `nil` when the producer cannot derive one cheaply.
    public let location: String?

    public init(code: String, message: String, location: String? = nil) {
        assert(!code.contains(" "), "fault code must be an identifier, not prose: \(code)")
        assert(code.contains("."), "fault code must be namespaced: \(code)")
        self.code = code
        self.message = message
        self.location = location
    }

    /// `message`, with the location appended when it is not already embedded.
    public var developerDescription: String {
        guard let location else { return message }
        guard !message.contains(location) else { return message }
        return "\(message) (\(location))"
    }
}
