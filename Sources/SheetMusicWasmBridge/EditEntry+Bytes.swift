import JavaScriptKit
import SheetMusicCore
import SheetMusicEditWire

/// Android: `nativeApplyEditIntent`, with an outcome channel instead of `Bool`.
/// This is the only way JavaScript can relay a `.composite` intent. The browser
/// treats the bytes as opaque data produced by another Swift image or a fixture;
/// undecodable bytes return `bridge.undecodableIntent`.
@JS public func applyEditIntentBytes(handle: Int, intentBytes: JSUint8Array) -> EditOutcome {
    let scoreHandle = Int64(handle)
    guard let session = session(for: scoreHandle) else {
        return bridgeRefusal(
            code: "bridge.noSession",
            operation: "applyEditIntentBytes",
            message: "no edit session is open",
        )
    }
    guard let intent = try? EditIntentCodec.decode(intentBytes.bridgedData) else {
        return bridgeRefusal(
            code: "bridge.undecodableIntent",
            operation: "applyEditIntentBytes",
            message: "intent bytes could not be decoded",
        )
    }
    guard session.apply(intent) else {
        return editRefusal(session.lastRefusal ?? EditRefusal(operation: "apply", reason: .nothingToApply))
    }
    guard publish(session.score, to: scoreHandle) else {
        return bridgeRefusal(
            code: "bridge.publishFailed",
            operation: "applyEditIntentBytes",
            message: "score handle is gone",
        )
    }
    return acceptedOutcome()
}
