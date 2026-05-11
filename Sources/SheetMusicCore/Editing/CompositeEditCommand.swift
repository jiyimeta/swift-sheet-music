import Foundation

/// Bundles several sub-commands into one atomic edit step. Apply
/// runs each sub-command in order, collecting their inverses; the
/// returned inverse is itself a `CompositeEditCommand` that replays
/// those inverses in reverse order. The whole bundle therefore
/// occupies a single slot on `ScoreEditor`'s undo stack — one ⌘Z
/// reverses the entire sequence.
///
/// Used by hosts for range paste / range cut / any multi-step edit
/// the user perceives as a single action. If a sub-command throws
/// part-way through, every already-applied sub-command is rolled
/// back via its inverse so the score is left untouched.
public struct CompositeEditCommand: EditCommand {
    public let commands: [any EditCommand]
    /// `VoiceElementID` reported as the affected location. Hosts
    /// use this to e.g. scroll the affected measure into view, so
    /// callers should pass whichever sub-command is "primary".
    public let location: VoiceElementID

    public init(
        commands: [any EditCommand],
        location: VoiceElementID,
    ) {
        self.commands = commands
        self.location = location
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        var inverses: [any EditCommand] = []
        for cmd in commands {
            do {
                let inv = try cmd.apply(to: &score)
                inverses.append(inv)
            } catch {
                // Roll back what we did so the partial edit isn't
                // visible to the caller.
                for prior in inverses.reversed() {
                    _ = try? prior.apply(to: &score)
                }
                throw error
            }
        }
        // Inverse replays the collected inverses in reverse — i.e.
        // the LAST sub-command's inverse runs first, peeling state
        // back to where the previous sub-command had left it.
        return CompositeEditCommand(
            commands: inverses.reversed(),
            location: location,
        )
    }
}
