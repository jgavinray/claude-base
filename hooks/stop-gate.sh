#!/usr/bin/env bash
# Stop hook: refuse to let the model stop while the project verifier is red.
#
# Mechanism: emit {"decision":"block","reason":...} on failure, which forces the
# turn to continue with the failure output injected as feedback. Exit-0 JSON is
# required — JSON on any other exit code is ignored by Claude Code.
#
# Difference from the ai-harness original: this gate is EDIT-TRIGGERED. If the
# session never wrote a file, there is nothing to verify and the hook exits
# immediately. Without that, every conversational turn — including answering a
# question — pays the cost of the full verifier, which is unusable in a repo
# whose verify.sh renders 200 manifests.
#
# Loop guard: per-session counter, capped at CLAUDE_STOP_GATE_MAX (default 8).
set -u

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')

STATE_DIR="${TMPDIR:-/tmp}"
EDIT_MARKER="$STATE_DIR/claude-base-edited-${SESSION_ID}"
COUNT_FILE="$STATE_DIR/claude-base-stopgate-${SESSION_ID}"
MAX_ITER="${CLAUDE_STOP_GATE_MAX:-8}"

# No file was written this session => nothing to gate.
[ -f "$EDIT_MARKER" ] || exit 0

# Resolve the project verifier. No verifier => nothing to gate.
VERIFY=""
if   [ -x "$CWD/.claude/verify.sh" ]; then VERIFY="$CWD/.claude/verify.sh"
elif [ -x "$CWD/verify.sh" ];         then VERIFY="$CWD/verify.sh"
fi
[ -z "$VERIFY" ] && exit 0

COUNT=0
[ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

if [ "$COUNT" -ge "$MAX_ITER" ]; then
  rm -f "$COUNT_FILE" "$EDIT_MARKER"
  jq -n --arg msg "stop-gate: iteration cap ($MAX_ITER) reached; releasing stop. Verification is still FAILING — inspect manually." \
    '{systemMessage: $msg}'
  exit 0
fi

TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
OUTPUT=$(cd "$CWD" && ${TIMEOUT_CMD:+"$TIMEOUT_CMD" 600} "$VERIFY" 2>&1)
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  rm -f "$COUNT_FILE" "$EDIT_MARKER"
  exit 0
fi

echo $((COUNT + 1)) > "$COUNT_FILE"
TAIL=$(printf '%s' "$OUTPUT" | tail -c 4000)

jq -n \
  --arg reason "verify.sh FAILED (exit $STATUS, attempt $((COUNT + 1))/$MAX_ITER). You are not done.

Fix the FIRST failure below, then re-run the verifier yourself before finishing.
Do not edit the check to make it pass, and do not argue that the failure is
unrelated — if it is genuinely unrelated, say so explicitly and stop.

$TAIL" \
  '{decision: "block", reason: $reason}'
exit 0
