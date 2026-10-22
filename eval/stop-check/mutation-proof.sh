#!/usr/bin/env bash
# Shows the stop-check section of tests/base-test.sh failing on broken hooks.
# For each mutation it copies the repo, breaks hooks/stop-check.sh one way, runs
# only the stop-check tests, and requires at least one FAIL. Exit 0 only if every
# mutation is caught.   Usage: eval/stop-check/mutation-proof.sh
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
rc=0
mutate() { # name, perl substitution (applied to the whole file)
  local name="$1" expr="$2" d="$W/$1"
  mkdir -p "$d" && (cd "$REPO" && tar --exclude=.git --exclude=omp -cf - .) | tar -xf - -C "$d"
  perl -0pi -e "$expr" "$d/hooks/stop-check.sh"
  if cmp -s "$REPO/hooks/stop-check.sh" "$d/hooks/stop-check.sh"; then echo "MUTATION DID NOT APPLY: $name"; rc=1; return; fi
  # run only the stop-check section of the suite against the mutated copy
  python3 -I - "$d" "$REPO/tests/base-test.sh" > "$d/section.sh" <<'PY'
import sys
d, suite = sys.argv[1], sys.argv[2]
t = open(suite).read()
a, b = t.index("# ---- stop-check"), t.index("# ---- post-edit-check")
head = "".join(t.splitlines(True)[:12]).replace('HERE="$(cd "$(dirname "$0")/.." && pwd)"', 'HERE=' + d)
sys.stdout.write(head + "export JEV_SHADOW_OFF_FILE=/\n" + t[a:b])
PY
  local fails; fails=$(bash "$d/section.sh" 2>&1 | grep -c '^FAIL')
  if [ "$fails" -gt 0 ]; then echo "caught  $name ($fails failing checks)"; else echo "MISSED  $name"; rc=1; fi
}
mutate no-loop-cap      's/\[ "\$\(count\)" -ge "\$MAX_BLOCKS" \]/false/'
mutate no-masking       's/mask\(\) \{ "\$HOOKDIR\/jev-shadow.sh" redact; \}/mask() { cat; }/'
mutate no-kill-switch   's/\[ -e "\$OFF_FILE" \] && exit 0//'
mutate fails-closed     's/\|\| allow "jev-error p=-"/|| { echo "{\\"decision\\":\\"block\\",\\"reason\\":\\"x\\"}"; exit 0; }/'
mutate no-timeout       's/curl -s -m "\$TIMEOUT"/curl -s/'
mutate invalid-block    's/jq -n --arg r "Stop check:.*?\n.*?\{decision: "block", reason: \$r\}\x27/echo block/s'
mutate counter-no-reset 's/reset\(\) \{ rm -f "\$COUNT_FILE" 2>\/dev\/null; return 0; \}/reset() { return 0; }/'
mutate ignores-bg-tasks 's/if \[ "\$\(printf .%s. "\$EV" \| jq -r .\(\.background_tasks.*?then allow "background-tasks p=-"; fi//s'
mutate wrong-model      's/model: "jev-stop-check"/model: "jev-glm-shadow"/'
exit $rc
