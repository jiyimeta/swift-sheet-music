#!/usr/bin/env bash
# Print the bin directory of the open-source swift.org Swift toolchain, or
# exit 1 if it is not installed.
#
# Cross-compiling needs that toolchain rather than the one Xcode ships —
# Apple's fork rejects the Android SDK's pre-built Foundation module, and it
# has no WebAssembly backend at all. See README "Toolchain".
#
# Two locations are searched because the .pkg installs to either, depending
# on how it was run:
#
#   installer -pkg … -target /                        → /Library/Developer/Toolchains
#   installer -pkg … -target CurrentUserHomeDirectory → ~/Library/Developer/Toolchains
#
# The first needs an administrator password; the second does not, which is
# what makes an unattended setup possible. Xcode and `xcrun --toolchain` read
# both. The system location wins when both are present, so a machine-wide
# install still takes precedence over a stale per-user one.
#
# Override the version with SWIFT_ORG_TOOLCHAIN_VERSION when bumping.
#
# Usage:
#   if bin="$(Scripts/swift-org-toolchain.sh)"; then export PATH="$bin:$PATH"; fi
set -euo pipefail

VERSION="${SWIFT_ORG_TOOLCHAIN_VERSION:-swift-6.3.3-RELEASE}"

for base in "/Library/Developer/Toolchains" "$HOME/Library/Developer/Toolchains"; do
    bin="$base/$VERSION.xctoolchain/usr/bin"
    if [ -x "$bin/swift" ]; then
        printf '%s\n' "$bin"
        exit 0
    fi
done

exit 1
