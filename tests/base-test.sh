#!/usr/bin/env bash
# claude-base regression suite. Run via ./.claude/verify.sh.
# Requires: bash, jq, git, python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
TMP="${TMPDIR:-/tmp}"

ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1${2:+ — $2}"; FAILURES=$((FAILURES+1)); }
T()    { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
TN()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n" "expected nonzero"; else ok "$n"; fi; }

# ---- static ------------------------------------------------------------------
for f in "$HERE"/hooks/*.sh "$HERE"/verify/verify.sh "$HERE"/install.sh "$HERE"/init-repo.sh; do
  T "syntax:$(basename "$f")" bash -n "$f"
done
T "json:settings.json" jq empty "$HERE/settings.json"
T "settings:hooks-use-HOME" bash -c "jq -r '.hooks[][].hooks[].command' '$HERE/settings.json' | grep -q '^\\\$HOME'"
# Only the hook COMMANDS must avoid $CLAUDE_PROJECT_DIR (it resolves to whichever
# repo is open, which is wrong for a globally-installed hook). Prose may mention it.
T "settings:no-project-dir" bash -c "! jq -r '.hooks[][].hooks[].command' '$HERE/settings.json' | grep -q CLAUDE_PROJECT_DIR"

for a in verifier code-reviewer qa-tester planner doc-manager; do
  T "agent:$a-frontmatter" bash -c "head -1 '$HERE/agents/$a.md' | grep -q -- '---'"
  T "agent:$a-name" bash -c "grep -q '^name: $a\$' '$HERE/agents/$a.md'"
done
T "skill:workflow-opt-in" grep -q "This is opt-in" "$HERE/skills/workflow/SKILL.md"
T "skill:uses-Agent-tool" grep -q "via the \*\*Agent\*\*" "$HERE/skills/workflow/SKILL.md"
T "skill:no-Task-tool" bash -c "! grep -q 'via the Task tool' '$HERE/skills/workflow/SKILL.md'"
T "rules:global-under-40-lines" bash -c "[ \$(wc -l < '$HERE/CLAUDE.md') -lt 40 ]"

# ---- pretool-guard -----------------------------------------------------------
G="$HERE/hooks/pretool-guard.sh"
guard() { printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | "$G"; }
guard_is() { # cmd, expected decision, label
  local out d
  out=$(guard "$1")
  # No output at all is the allow path — the hook stays silent and the tool runs.
  if [ -z "$out" ]; then
    d="allow"
  else
    d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo parse-error)
  fi
  if [ "$d" = "$2" ]; then ok "guard:$2:$3"; else bad "guard:$2:$3" "got '$d'"; fi
}
guard_is 'rm -rf /'                              deny  "rm-rf-root"
guard_is 'rm  -r  -f  /'                         deny  "rm-split-flags"
guard_is 'rm -rf "/"'                            deny  "rm-quoted"
guard_is 'rm -rf $HOME'                          deny  "rm-home"
guard_is 'mkfs.ext4 /dev/sda1'                   deny  "mkfs"
guard_is 'dd if=/dev/zero of=/dev/sda'           deny  "dd-device"
guard_is 'terraform destroy -auto-approve'       deny  "tf-destroy"
guard_is 'kubectl delete namespace prod'         deny  "kubectl-ns"
guard_is 'kubectl delete pods --all -n prod'     deny  "kubectl-all"
guard_is 'kubectl delete pvc data-0'             deny  "kubectl-pvc"
guard_is 'helm uninstall my-release'             deny  "helm-uninstall"
guard_is 'argocd app delete my-app'              deny  "argocd-delete"
guard_is 'aws s3 rb s3://bucket'                 deny  "s3-rb"
guard_is 'az group delete -n rg'                 deny  "az-group"
guard_is 'git push --force origin main'          deny  "force-push"
guard_is 'DROP DATABASE prod;'                   deny  "drop-db"
guard_is 'git push --force-with-lease origin hf' allow "force-with-lease-ok"
guard_is 'kubectl delete pod nginx-1'            ask   "kubectl-pod"
guard_is 'terraform apply'                       ask   "tf-apply"
guard_is 'git reset --hard HEAD~1'               ask   "git-reset"
guard_is 'docker system prune -f'                ask   "docker-prune"
guard_is 'npm publish'                           ask   "npm-publish"
# Recursive delete: allowlist semantics. The textbook `rm -rf /` is not the case
# that happens; wiping a project directory is. Every line below was `allow` under
# the original denylist.
guard_is 'rm -rf ~'                              deny  "rm-home-bare"
guard_is 'rm -rf *'                              deny  "rm-glob-all"
guard_is 'rm -rf .'                              deny  "rm-dot"
guard_is 'rm -rf ..'                             deny  "rm-dotdot"
guard_is 'rm -rf ~/dev/ai-harness'               deny  "rm-under-home"
guard_is 'rm -rf $HOME/dev'                      deny  "rm-home-subdir"
guard_is 'rm -rf /Users/jgavinray/dev/catapult'  deny  "rm-abs-project"
guard_is 'rm -r --recursive /etc'                deny  "rm-abs-etc"
guard_is 'rm -rf ./src'                          ask   "rm-source-dir"
guard_is 'rm -rf mypackage'                      ask   "rm-unknown-dir"
guard_is 'find . -name "*.py" -delete'           ask   "find-delete"
guard_is 'find . -exec rm {} \;'                 ask   "find-exec-rm"
guard_is 'rm -rf node_modules'                   allow "rm-node-modules"
guard_is 'rm -rf ./build'                        allow "rm-build"
guard_is 'rm -rf target/debug'                   allow "rm-target"
guard_is 'rm -rf .venv'                          allow "rm-venv"
guard_is 'rm -rf dist && npm run build'          allow "rm-dist-chained"
guard_is 'rm -rf /tmp/scratch'                   allow "rm-tmp"
guard_is 'rm -f server.log'                      allow "rm-nonrecursive-with-r-in-name"
guard_is 'rm -f config.json'                     allow "rm-single-file"
guard_is 'ls -la'                                allow "ls"
guard_is 'kubectl get pods -A'                   allow "kubectl-get"
guard_is 'git status'                            allow "git-status"
guard_is 'rm -rf ./build'                        allow "rm-local-build"
guard_is 'pytest -q'                             allow "pytest"

# ---- post-edit-check ---------------------------------------------------------
P="$HERE/hooks/post-edit-check.sh"
W=$(mktemp -d); SID="basetest-$$"
rm -f "$TMP/claude-base-edited-$SID"
pec() { printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$1" | "$P"; }

printf 'x = 1\n' > "$W/good.py"
T  "postedit:good-python" pec "$W/good.py"
T  "postedit:marker-written" test -f "$TMP/claude-base-edited-$SID"
printf 'def f(:\n' > "$W/bad.py"
TN "postedit:bad-python-blocks" pec "$W/bad.py"
printf 'a: 1\nb: 2\n' > "$W/good.yaml"
T  "postedit:good-yaml" pec "$W/good.yaml"
printf 'a: [1, 2\n' > "$W/bad.yaml"
TN "postedit:bad-yaml-blocks" pec "$W/bad.yaml"
printf 'key: {{ .Values.x }}\n' > "$W/helm.yaml"
T  "postedit:helm-template-skipped" pec "$W/helm.yaml"
printf '{"a":1}\n' > "$W/good.json"
T  "postedit:good-json" pec "$W/good.json"
printf '{"a":\n' > "$W/bad.json"
TN "postedit:bad-json-blocks" pec "$W/bad.json"
T  "postedit:missing-file-noop" pec "$W/nope.py"

# ---- stop-gate ---------------------------------------------------------------
S="$HERE/hooks/stop-gate.sh"
GW=$(mktemp -d); mkdir -p "$GW/.claude"
sg() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop"}' "$1" "$GW" | "$S"; }

printf '#!/usr/bin/env bash\necho FAILMARK\nexit 1\n' > "$GW/.claude/verify.sh"
chmod +x "$GW/.claude/verify.sh"

# no edit marker => gate must not fire at all (the interactive-cost fix)
SID2="basetest-noedit-$$"
rm -f "$TMP/claude-base-edited-$SID2" "$TMP/claude-base-stopgate-$SID2"
OUT=$(sg "$SID2")
if [ -z "$OUT" ]; then ok "stopgate:silent-without-edits"; else bad "stopgate:silent-without-edits" "emitted: $OUT"; fi

# with marker + failing verifier => block
SID3="basetest-edit-$$"
rm -f "$TMP/claude-base-stopgate-$SID3"; : > "$TMP/claude-base-edited-$SID3"
OUT=$(sg "$SID3")
T "stopgate:blocks-on-fail" bash -c "printf '%s' '$OUT' | jq -e '.decision == \"block\"'"
T "stopgate:includes-output"  bash -c "printf '%s' '$OUT' | grep -q FAILMARK"
T "stopgate:counter-incremented" test -f "$TMP/claude-base-stopgate-$SID3"

# passing verifier => silent, and both marker + counter cleared
printf '#!/usr/bin/env bash\nexit 0\n' > "$GW/.claude/verify.sh"
OUT=$(sg "$SID3")
if [ -z "$OUT" ]; then ok "stopgate:silent-on-pass"; else bad "stopgate:silent-on-pass" "emitted: $OUT"; fi
T "stopgate:marker-cleared"  bash -c "[ ! -f '$TMP/claude-base-edited-$SID3' ]"
T "stopgate:counter-cleared" bash -c "[ ! -f '$TMP/claude-base-stopgate-$SID3' ]"

# cap released
printf '#!/usr/bin/env bash\nexit 1\n' > "$GW/.claude/verify.sh"
SID4="basetest-cap-$$"; : > "$TMP/claude-base-edited-$SID4"
echo 8 > "$TMP/claude-base-stopgate-$SID4"
OUT=$(sg "$SID4")
T "stopgate:cap-releases" bash -c "printf '%s' '$OUT' | jq -e '.systemMessage | test(\"cap\")'"
T "stopgate:cap-no-block" bash -c "! printf '%s' '$OUT' | jq -e '.decision' >/dev/null 2>&1"

# no verifier at all => silent
rm -f "$GW/.claude/verify.sh"
SID5="basetest-noverify-$$"; : > "$TMP/claude-base-edited-$SID5"
OUT=$(sg "$SID5")
if [ -z "$OUT" ]; then ok "stopgate:silent-without-verifier"; else bad "stopgate:silent-without-verifier"; fi

# ---- verify.sh ---------------------------------------------------------------
V="$HERE/verify/verify.sh"
mkrepo() { local d; d=$(mktemp -d); git -C "$d" init -q; mkdir -p "$d/.claude"; cp "$V" "$d/.claude/verify.sh"; chmod +x "$d/.claude/verify.sh"; echo "$d"; }

R=$(mkrepo)
T "verify:empty-repo-lists-NONE" bash -c "cd '$R' && ./.claude/verify.sh --list | grep -qx NONE"
T "verify:empty-repo-exits-0"    bash -c "cd '$R' && ./.claude/verify.sh"
T "verify:empty-repo-warns-inert" bash -c "cd '$R' && ./.claude/verify.sh 2>&1 | grep -q 'INERT'"

# yaml-only repo: the 53%-of-the-fleet case must produce a real gate
R2=$(mkrepo)
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n' > "$R2/cm.yaml"
git -C "$R2" add -A >/dev/null 2>&1
if command -v yq >/dev/null 2>&1 || python3 -c "import yaml" >/dev/null 2>&1; then
  T  "verify:yaml-repo-armed"  bash -c "cd '$R2' && ./.claude/verify.sh --list | grep -q yaml-parse"
  T  "verify:yaml-good-passes" bash -c "cd '$R2' && ./.claude/verify.sh"
  printf 'a: [1, 2\n' > "$R2/broken.yaml"
  git -C "$R2" add -A >/dev/null 2>&1
  TN "verify:yaml-bad-fails"   bash -c "cd '$R2' && ./.claude/verify.sh"
  # Helm templates must not be treated as YAML
  R3=$(mkrepo); mkdir -p "$R3/templates"
  printf 'kind: {{ .Values.kind }}\n' > "$R3/templates/deploy.yaml"
  git -C "$R3" add -A >/dev/null 2>&1
  T  "verify:helm-template-not-yaml-failure" bash -c "cd '$R3' && ./.claude/verify.sh"
else
  echo "SKIP verify:yaml-* (PyYAML not installed)"
fi

# repo-specific checks.sh is picked up and can fail the gate
R4=$(mkrepo)
printf '#!/usr/bin/env bash\nexit 3\n' > "$R4/.claude/checks.sh"; chmod +x "$R4/.claude/checks.sh"
T  "verify:checks-detected" bash -c "cd '$R4' && ./.claude/verify.sh --list | grep -q repo-checks"
TN "verify:checks-can-fail" bash -c "cd '$R4' && ./.claude/verify.sh"

# full override wins
R5=$(mkrepo)
printf '#!/usr/bin/env bash\necho OVERRIDE\nexit 0\n' > "$R5/.claude/verify.local.sh"; chmod +x "$R5/.claude/verify.local.sh"
T "verify:local-override-listed" bash -c "cd '$R5' && ./.claude/verify.sh --list | grep -q 'verify.local'"
T "verify:local-override-runs"   bash -c "cd '$R5' && ./.claude/verify.sh | grep -q OVERRIDE"

# shell syntax check catches a broken script
R6=$(mkrepo)
printf '#!/usr/bin/env bash\nif [ 1 ; then\n' > "$R6/broken.sh"
git -C "$R6" add -A >/dev/null 2>&1
TN "verify:sh-syntax-fails" bash -c "cd '$R6' && ./.claude/verify.sh"

# ---- session-context ---------------------------------------------------------
SC="$HERE/hooks/session-context.sh"
sc() { printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$1" | "$SC" 2>/dev/null; }
# NOTE: capture, then match. Do NOT pipe into `grep -q` here — grep -q exits on
# first match, the writer takes SIGPIPE, and `set -o pipefail` reports 141 for a
# pipeline that actually succeeded.
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

R7=$(mkrepo)
printf '#!/usr/bin/env bash\nexit 0\n' > "$R7/.claude/checks.sh"; chmod +x "$R7/.claude/checks.sh"
R8=$(mktemp -d); git -C "$R8" init -q

T "sessctx:reports-inert"  has "$(sc "$R")"  "GATE INERT"
T "sessctx:reports-armed"  has "$(sc "$R7")" "GATE ARMED"
T "sessctx:reports-absent" has "$(sc "$R8")" "GATE ABSENT"

# a hook dir missing its siblings must announce the gap rather than fail silently
SCD=$(mktemp -d); cp "$SC" "$SCD/session-context.sh"; chmod +x "$SCD/session-context.sh"
LONE=$(printf '{"cwd":"%s"}' "$R8" | "$SCD/session-context.sh" 2>/dev/null)
T "sessctx:warns-missing-hook" has "$LONE" "silently ABSENT"
rm -rf "$SCD"

# ---- install.sh dry-run is inert --------------------------------------------
T "install:dry-run-clean" bash -c "'$HERE/install.sh' --dry-run | grep -q 'would:'"
T "install:dry-run-no-writes" bash -c "
  BEFORE=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | md5 2>/dev/null || ls -la \"\$HOME/.claude\" | md5sum)
  '$HERE/install.sh' --dry-run >/dev/null
  AFTER=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | md5 2>/dev/null || ls -la \"\$HOME/.claude\" | md5sum)
  [ \"\$BEFORE\" = \"\$AFTER\" ]"

rm -rf "$W" "$GW" "$R" "$R2" "${R3:-}" "$R4" "$R5" "$R6" "$R7" "$R8" 2>/dev/null
rm -f "$TMP/claude-base-edited-basetest-"* "$TMP/claude-base-stopgate-basetest-"* 2>/dev/null

echo "----"
if [ "$FAILURES" -eq 0 ]; then echo "base-test: all green"; else echo "base-test: $FAILURES failure(s)"; fi
exit $((FAILURES > 0))
