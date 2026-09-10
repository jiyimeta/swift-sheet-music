import SheetMusicFoundation

/// An edit with its repairs, together with the post-edit preview those repairs were planned against.
///
/// `preview` and `idAllocator` describe the score after the edit and before the repairs. The allocator is also what
/// replaying `command` ends with, but only because every repair keeps its slots' identifiers
/// (`ReplaceVoiceElements(elements:)` is all `.keep`) and so mints nothing; a repair with a `.fresh` slot would make
/// it fall short. The allocator is a value snapshot: only replaying `command` advances the caller's allocator.
struct AccidentalRenotationPlan {
    let command: any EditCommand
    let preview: Score
    let idAllocator: EIDAllocator
    let repairs: [any EditCommand]
}
