import Foundation

/// Owns a block-based `NotificationCenter` observer token and unregisters it on dealloc.
///
/// `PlaybackEngine` could hold the token directly, but then it would have to unregister from its own `deinit` —
/// which is `nonisolated` and so cannot read a `var` stored property on a `@MainActor` type (an `isolated deinit`
/// would need iOS 18; this package deploys to iOS 17). Parking the token in its own, unisolated object moves the
/// removal into *that* object's deinit, which the engine releasing it triggers all the same.
///
/// One instance per observed notification: the engine holds one for `AVAudioSession.interruptionNotification`
/// (`PlaybackEngine+AudioSession`) and one for `AVAudioEngineConfigurationChange`
/// (`PlaybackEngine+ConfigurationChange`).
final class NotificationObserverToken {
    var token: (any NSObjectProtocol)?

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
