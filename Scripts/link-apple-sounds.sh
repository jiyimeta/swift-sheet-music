#!/usr/bin/env bash
# Symlink `Examples/Apple/SheetMusicExample/Sounds/` from this worktree to
# the main worktree's copy. The directory is gitignored — its sole content
# (`MuseScore_General.sf2`, ~215 MB) is distributed via GitHub Releases,
# not git, and lives once in the main worktree. Linking from each secondary
# worktree avoids duplicating the file and keeps the Apple example app
# runnable.
#
# Usage: Scripts/link-apple-sounds.sh
#   Run once from any worktree root (or any subdirectory of it) after
#   creating the worktree. Idempotent; no-op from the main worktree.
set -euo pipefail

# Main worktree root = the directory containing the canonical `.git/`.
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
MAIN_ROOT=$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd -P)

# This worktree's root.
CURRENT_ROOT=$(git rev-parse --show-toplevel)

if [ "$MAIN_ROOT" = "$CURRENT_ROOT" ]; then
    echo "Already in main worktree — nothing to link."
    exit 0
fi

SOURCE="$MAIN_ROOT/Examples/Apple/SheetMusicExample/Sounds"
TARGET="$CURRENT_ROOT/Examples/Apple/SheetMusicExample/Sounds"

if [ ! -d "$SOURCE" ]; then
    cat >&2 <<EOF
ERROR: main worktree's Sounds/ not found at:
    $SOURCE

Download the SoundFont per README §"SoundFonts" first (place
\`MuseScore_General.sf2\` in that directory), then re-run this script.
EOF
    exit 1
fi

if [ -L "$TARGET" ]; then
    EXISTING=$(readlink "$TARGET")
    if [ "$EXISTING" = "$SOURCE" ]; then
        echo "Already linked: $TARGET -> $SOURCE"
        exit 0
    fi
    echo "Replacing stale symlink ($TARGET -> $EXISTING)"
    rm "$TARGET"
elif [ -e "$TARGET" ]; then
    echo "ERROR: $TARGET exists and is not a symlink. Move or delete it manually." >&2
    exit 1
fi

ln -s "$SOURCE" "$TARGET"
echo "Linked: $TARGET -> $SOURCE"
