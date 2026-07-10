# Security Policy

## Supported versions

This project is pre-1.0. Only the latest release (and the `main` branch)
receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's
[Report a vulnerability](https://github.com/jiyimeta/swift-sheet-music/security/advisories/new)
form, or by email to jiyi.meta@gmail.com.

Include a description, reproduction steps, and the affected version. You
should get an acknowledgement within a few days.

Because this is a parsing library, malformed-input handling in the MSCX /
MusicXML / MIDI decoders — crashes, unbounded memory or time on crafted
files — is in scope.
