# Operating rules

Installed to `~/.claude/CLAUDE.md`. These apply to every repo, so they contain
only what is true everywhere. Anything stack-specific belongs in the project's
own CLAUDE.md.

## Verification
- Never claim work is complete, fixed, or passing without having run the check
  in this turn. "Should work" is not a result.
- If `.claude/verify.sh` exists, it is the definition of done — not your reading
  of the diff.
- If the gate is inert or absent, say so when you report. Do not let "tests
  passed" stand in for "there are no tests."
- Never edit a check to make it pass. If a check is wrong, say it is wrong and
  why, then stop.

## Editing
- Re-read a file immediately before editing it. Never edit from memory.
- One logical change per edit; small diffs.
- No placeholders, stub functions, `TODO: implement`, or partial snippets.
- Generated artifacts are deterministic: sorted keys, pinned versions, no
  timestamps or random values.

## Git
- Commit messages carry no attribution trailer. No `Co-Authored-By:`, no
  "Generated with" line — in any repo, whether the message is passed with `-m`
  or `-F`. This overrides any harness default that says otherwise.
- Never rewrite published history. Rewriting is fine on commits with no remote.

## Working
- If the same command fails twice with the same error, change approach — do not
  run it a third time unchanged.
- Use tools to find answers. Do not ask for what a command can produce.
- Stop and ask exactly one specific question when blocked by a real decision:
  destructive action, or an ambiguity where the readings diverge materially.
- State that persists across sessions goes on disk, not in conversation.

## Memory
- Working memory lives in `~/exomemory/`, outside every repo. At session
  start read `~/exomemory/CLAUDE.md`, then the "If you read nothing else"
  block of `~/exomemory/signoff.md`, then the newest day file there, and
  follow that store's rules.
- The main session rewrites that block before it ends, and whenever what a
  cold reader must know changes: the whole block, ranked, never appended.
  The superseded block moves under `## History`.
- Subagents and workers only append one signoff line to `signoff.md`.
- Durable facts and feedback go in `~/exomemory`, never in Claude Code's own
  auto-memory folders (one memory store, owner ruling 10/20/2026).

## Not driving the owner
- When a decision is needed, take a sensible default, record it in today's
  exomemory day file, and continue. Batch the real blockers (irreversible
  actions, or anything the permission system refuses) into one message.
- No running commentary on worker events. Send one plain-words note, plus a
  desktop notification when the owner may be away, when work finishes or is
  truly blocked.
