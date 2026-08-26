#!/usr/bin/env bash
# Rejects structured-error regressions that are awkward to express as type
# checks: authored `.unexpected` edit refusals and prose operation names.
#
# Both patterns are matched WITHOUT requiring the enclosing label on the same
# line. Nearly every `EditRefusal` in the tree is built across several lines, so
# a same-line pattern would pass by matching nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

SEARCH_ROOTS=(Sources Tests Examples Tools Package.swift)

# `.unexpected` exists to keep a foreign error visible rather than crash on it.
# Only the session that catches such an error may build one; anywhere else it
# is free text wearing an enum's clothes. The test that asserts on every
# `Reason` case has to name it too, so it is exempt by path.
#
# `case .unexpected` / `case let .unexpected(x)` is a pattern match, not a
# construction — consumers switching over `Reason` are exactly what the typed
# enum is for, so those lines are dropped rather than reported.
unexpected_violations=$(
    grep -RIn --include='*.swift' '\.unexpected(' "${SEARCH_ROOTS[@]}" 2>/dev/null \
        | grep -v '^Sources/SheetMusicCore/Editing/ScoreEditSession\.swift:' \
        | grep -v '^Tests/SheetMusicTests/EditingTests/EditRefusalTests\.swift:' \
        | grep -vE ':[0-9]+:[[:space:]]*case([[:space:]]+let)?[[:space:]]' \
        || true
)

# `operation` names the refusing command or entry point, for logs and triage.
# A space means someone wrote a sentence; the sentence belongs in the `Reason`.
# `EditRefusal` owns every `operation:` label in the tree, so this needs no
# further scoping.
operation_violations=$(
    grep -RIn --include='*.swift' 'operation:[[:space:]]*"[^"]*[[:space:]][^"]*"' "${SEARCH_ROOTS[@]}" 2>/dev/null || true
)

status=0

if [[ -n "$unexpected_violations" ]]; then
    echo "error: EditRefusal.Reason.unexpected may only be constructed by ScoreEditSession.swift." >&2
    echo "$unexpected_violations" >&2
    status=1
fi

if [[ -n "$operation_violations" ]]; then
    echo "error: EditRefusal operation literals must be identifiers, not prose." >&2
    echo "$operation_violations" >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

echo "Error-code gates passed."
