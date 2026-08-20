# Claude Code entrypoint

Read and follow `AGENTS.md`; it is the canonical repository guidance shared by
Claude Code, standalone Codex, and Codex sessions delegated from Claude.

Claude-specific notes:

- Keep Claude-created worktrees under `.claude/worktrees/`.
- When delegating to Codex, pass the repository root as the absolute `cwd`,
  bound the delegated goal, and require concrete verification evidence.
- Do not duplicate shared project facts or workflows here. Update `AGENTS.md`
  or the linked project documentation instead.
