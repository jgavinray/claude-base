#!/usr/bin/env bash
# SessionStart: plain stdout is injected as context. Give the model ground truth
# at turn zero so it does not spend the first three tool calls rediscovering it.
#
# The important line is the LAST one: whether the gate actually has teeth here.
# A verifier that exists but detects no checks is worse than no verifier, because
# it reports green. This hook names that state instead of hiding it.
set -u
cd "$(jq -r '.cwd // "."')" 2>/dev/null || exit 0

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "branch: $(git branch --show-current 2>/dev/null)  |  last: $(git log -1 --oneline 2>/dev/null)"
  DIRTY=$(git status --porcelain 2>/dev/null | head -15)
  [ -n "$DIRTY" ] && printf 'uncommitted:\n%s\n' "$DIRTY"
fi

[ -f TASKS.md ] && { echo "--- TASKS.md ---"; head -25 TASKS.md; }
[ -f .claude/wf-state.json ] && { echo "--- workflow state (resume here) ---"; cat .claude/wf-state.json; }

# Fail-open detector: a guard you believe in but that is not wired is worse than
# no guard, because you stop checking. Hooks fail open, so say so out loud.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for h in pretool-guard.sh post-edit-check.sh stop-gate.sh; do
  [ -x "$HOOK_DIR/$h" ] || echo "WARNING: hook $h missing or not executable — that guard is silently ABSENT"
done

# Gate status: run detection only (fast), never the checks themselves.
if [ -x .claude/verify.sh ]; then
  CHECKS=$(.claude/verify.sh --list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  if [ -z "$CHECKS" ] || [ "$CHECKS" = "NONE" ]; then
    echo "GATE INERT: .claude/verify.sh exists but detects no checks in this repo."
    echo "  => 'done' is undefined here. A green verifier proves nothing until you"
    echo "     add checks to .claude/checks.sh. Do not claim verified work."
  else
    echo "GATE ARMED: .claude/verify.sh runs [$CHECKS] — it must exit 0 before you finish."
  fi
else
  echo "GATE ABSENT: no .claude/verify.sh. Nothing enforces correctness in this repo;"
  echo "  state that plainly rather than implying work was verified."
fi
exit 0
