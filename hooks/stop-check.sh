#!/usr/bin/env bash
# Stop / SubagentStop hook: "stop or continue?", decided by the local Jev service (GLM).
#
#   stop-check.sh            reads the stop event JSON on stdin. Prints nothing to
#                            allow the stop, or {"decision":"block","reason":...}
#                            to make the agent carry on.
#   stop-check.sh question   prints the question sent to the service (JSON).
#   stop-check.sh score      reads {"assistant":...,"user":...} on stdin, asks the
#                            service the same question and prints the raw answer.
#                            Used by the eval (eval/stop-check/), no decision logic.
#
# The problem it solves: sessions and workers stop and hand work back (ask
# permission for reversible things, tell the owner to run commands, propose next
# steps instead of doing them). Written rules did not fix that; this enforces it.
#
# What it does, in order (the first rule that fires wins, and every path that does
# not block allows the stop):
#   1. kill switch ~/.claude/stop-check-off exists                 -> allow
#   2. the event lists background tasks still running              -> allow (waiting)
#   3. 2 blocks in a row already for this session/agent            -> allow, counter reset
#   4. no text, or curl/jq/perl/jev-shadow.sh missing              -> allow
#   5. ask Jev (4 s limit); down, slow or any error                -> allow (fail open)
#   6. P(handing_back) >= threshold                                -> block, counter + 1
#      otherwise                                                   -> allow, counter reset
#
# Secrets are masked HERE (jev-shadow.sh redact) before anything leaves the machine.
# The service masks again and logs every decision (decisions.jsonl on hyper01).
#
# Settings (environment): STOP_CHECK_URL (default: the hyper01 LAN address from the
# local file below, else http://hyper01.puma-wyvern.ts.net:8102),
# STOP_CHECK_TIMEOUT seconds (4), STOP_CHECK_THRESHOLD (see THRESHOLD below),
# STOP_CHECK_MAX_BLOCKS (2), STOP_CHECK_OFF_FILE (~/.claude/stop-check-off),
# STOP_CHECK_STATE_DIR (per-user temp dir), STOP_CHECK_LOG (~/.claude/stop-check.log,
# one line per decision, no message text), STOP_CHECK_QUESTION_FILE (eval only).
set -u

THRESHOLD_DEFAULT="0.65"   # chosen on the training split; see eval/stop-check/RESULTS.md
HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The owner's LAN addresses are not kept in this public repo. A host's LAN
# address is read at run time from the untracked file named by $CLAUDE_BASE_LOCAL
# (default ~/.config/fleet-control/local.toml, the same file fleet-control uses):
#   [hosts.hyper01]
#   address = "<LAN address>"
# No file, or no entry: empty, and the caller falls back to the Tailscale name.
lan_addr() {
  local f="${CLAUDE_BASE_LOCAL:-$HOME/.config/fleet-control/local.toml}" a
  [ -r "$f" ] || return 0
  a=$(awk -v h="$1" '/^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); on = (s == "[hosts." h "]"); next }
    on && /^[[:space:]]*address[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*"/, "", v); sub(/".*$/, "", v); print v; exit }' "$f" 2>/dev/null)
  case "$a" in ''|*[!0-9A-Za-z.:-]*) return 0 ;; esac
  printf '%s' "$a"
}
H01=$(lan_addr hyper01)
URL="${STOP_CHECK_URL:-http://${H01:-hyper01.puma-wyvern.ts.net}:8102}"
TIMEOUT="${STOP_CHECK_TIMEOUT:-4}"
THRESHOLD="${STOP_CHECK_THRESHOLD:-$THRESHOLD_DEFAULT}"
MAX_BLOCKS="${STOP_CHECK_MAX_BLOCKS:-2}"
OFF_FILE="${STOP_CHECK_OFF_FILE:-$HOME/.claude/stop-check-off}"
STATE_DIR="${STOP_CHECK_STATE_DIR:-${TMPDIR:-/tmp}/stop-check-$(id -u)}"
LOG="${STOP_CHECK_LOG:-$HOME/.claude/stop-check.log}"
A_CAP=2000   # characters kept from the END of the agent's last message
U_CAP=400    # characters kept from the START of the message it was answering

read -r -d '' QUESTION <<'JSON'
{"criteria":{"answered":"the message is a straight answer to what the user asked","done":"work complete and verified; the message reports results","handing_back":"the agent stopped short: it asks permission for a reversible step, tells the owner to run a command, lists choices without picking one, or proposes next steps it should simply do","owner_only":"a step only the owner can take or approve: new passwords or tokens, account logins, payments, deleting their only copy of data, publishing to a third party, or destroying work that is not the agent's (another session's files or processes, a shared host)","waiting_on_background":"the agent started workers or background jobs that will notify it, and says it is waiting for them"},"instructions":"Judge this stop by an AI coding agent. Did it stop because it is finished or truly blocked, or did it hand work back that it could have done itself?","type":"choice"}
JSON

if [ -n "${STOP_CHECK_QUESTION_FILE:-}" ]; then
  QUESTION="$(jq -c '. + {type:"choice"}' "$STOP_CHECK_QUESTION_FILE")" || exit 0
fi

mask() { "$HOOKDIR/jev-shadow.sh" redact; }

# state text sent to the service (one place, so the eval and the hook agree)
build_state() { # $1 = agent message, $2 = message it answered
  jq -rn --arg a "$1" --arg u "$2" --argjson ac "$A_CAP" --argjson uc "$U_CAP" \
    '"The message the agent was answering (context only):\n" + ($u | .[0:$uc]) + "\n\nThe agent'"'"'s final message, where it stops:\n" + ($a | if length > $ac then .[(length - $ac):] else . end)'
}

ask() { # $1 = masked state text; prints the service answer, returns curl's status
  printf '%s' "$1" | jq -Rs --argjson q "$QUESTION" '{state: ., model: "jev-stop-check", questions: {stop: $q}}' |
    curl -s -m "$TIMEOUT" --connect-timeout 2 -H 'content-type: application/json' -d @- "$URL/v1/systemone"
}

if [ "${1:-}" = "question" ]; then printf '%s\n' "$QUESTION"; exit 0; fi

command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || exit 0
[ -x "$HOOKDIR/jev-shadow.sh" ] || exit 0

if [ "${1:-}" = "score" ]; then
  IN="$(cat)"
  A="$(printf '%s' "$IN" | jq -r '.assistant // ""' | mask)"
  U="$(printf '%s' "$IN" | jq -r '.user // ""' | mask)"
  ask "$(build_state "$A" "$U")"
  exit 0
fi

log() { # decision, detail
  { mkdir -p "$(dirname "$LOG")" && printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${EVENT:-?}" "$1" "${2:-}" >> "$LOG"; } 2>/dev/null
  return 0
}

[ -e "$OFF_FILE" ] && exit 0

EV="$(cat)"
printf '%s' "$EV" | jq -e . >/dev/null 2>&1 || exit 0
EVENT="$(printf '%s' "$EV" | jq -r '.hook_event_name // "Stop"')"
SID="$(printf '%s' "$EV" | jq -r '.session_id // "nosession"')"
AID="$(printf '%s' "$EV" | jq -r '.agent_id // "main"')"
KEY="$(printf '%s-%s' "$SID" "$AID" | tr -c 'A-Za-z0-9_-' '_')"
COUNT_FILE="$STATE_DIR/$KEY.blocks"

count() { local c; c="$(cat "$COUNT_FILE" 2>/dev/null)"; case "$c" in ''|*[!0-9]*) c=0;; esac; printf '%s' "$c"; }
reset() { rm -f "$COUNT_FILE" 2>/dev/null; return 0; }
allow() { reset; log allow "$1"; exit 0; }

# 2. background work still running: the agent is waiting on it, which is fine
if [ "$(printf '%s' "$EV" | jq -r '(.background_tasks // []) | length')" -gt 0 ]; then allow "background-tasks p=-"; fi

# 3. loop cap
if [ "$(count)" -ge "$MAX_BLOCKS" ]; then allow "loop-cap p=-"; fi

# the agent's last message: from the event, else from the transcript
A="$(printf '%s' "$EV" | jq -r '.last_assistant_message // ""')"
TP="$(printf '%s' "$EV" | jq -r '.transcript_path // ""')"
ATP="$(printf '%s' "$EV" | jq -r '.agent_transcript_path // ""')"
TEXT_OF='fromjson? | select(.type=="user") | .message.content | if type=="string" then . else (if any(.[]; .type=="tool_result") then empty else ([.[] | select(.type=="text") | .text] | join("\n")) end) end | select(length > 0)'
if [ -z "$A" ]; then
  F="${ATP:-$TP}"
  [ -r "$F" ] && A="$(tail -c 2000000 "$F" | jq -R -r 'fromjson? | select(.type=="assistant") | [.message.content[]? | select(.type=="text") | .text] | join("\n") | select(length > 0)' 2>/dev/null | tail -n 1)"
fi
[ -n "$(printf '%s' "$A" | tr -d '[:space:]')" ] || allow "no-text p=-"

# the message it was answering: the last owner message (Stop) or the brief (SubagentStop)
U=""
if [ "$EVENT" = "SubagentStop" ] && [ -r "$ATP" ]; then
  U="$(head -n 60 "$ATP" | jq -R -c "$TEXT_OF" 2>/dev/null | head -n 1 | jq -r '.' 2>/dev/null)"
elif [ -r "$TP" ]; then
  U="$(tail -c 3000000 "$TP" | jq -R -c "$TEXT_OF" 2>/dev/null | tail -n 1 | jq -r '.' 2>/dev/null)"
fi

AM="$(printf '%s' "$A" | tail -c 6000 | mask)"
UM="$(printf '%s' "$U" | head -c 2000 | mask)"
STATE="$(build_state "$AM" "$UM")"

# 5. ask Jev; any failure allows the stop
RESP="$(ask "$STATE" 2>/dev/null)" || allow "jev-error p=-"
P="$(printf '%s' "$RESP" | jq -r '.answers.stop.probabilities.handing_back // empty' 2>/dev/null)"
case "$P" in ''|*[!0-9.eE+-]*) allow "jev-bad-answer p=-";; esac

# 6. decide
if awk -v p="$P" -v t="$THRESHOLD" 'BEGIN { exit !(p >= t) }'; then
  N=$(( $(count) + 1 ))
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$N" > "$COUNT_FILE" 2>/dev/null
  PCT="$(awk -v p="$P" 'BEGIN { printf "%d", p * 100 + 0.5 }')"
  log block "p=$P block=$N"
  jq -n --arg r "Stop check: this stop was judged a handback with probability ${PCT}%, meaning you are ending your turn with work you could do yourself. Do the reversible version yourself instead of asking or telling the owner to run it, keep only owner-only items (passwords and tokens, account logins, payments, deleting their only copy of data, publishing to a third party, or destroying work that is not yours) for the owner, and continue." \
    '{decision: "block", reason: $r}'
  exit 0
fi
allow "ok p=$P"
