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
T "settings:no-attribution" bash -c "jq -e '.attribution.commit == \"\" and .attribution.pr == \"\"' '$HERE/settings.json'"
T "license:gplv2-present" bash -c "grep -q 'GNU GENERAL PUBLIC LICENSE' '$HERE/LICENSE' && grep -q 'Version 2, June 1991' '$HERE/LICENSE'"
T "license:readme-states-gplv2" grep -q "GNU General Public License" "$HERE/README.md"
T "readme:documents-baseline" grep -q "baseline" "$HERE/README.md"
T "rules:no-coauthored-rule" grep -q "no attribution trailer" "$HERE/CLAUDE.md"
T "rules:global-under-40-lines" bash -c "[ \$(wc -l < '$HERE/CLAUDE.md') -lt 40 ]"

# ---- pretool-guard -----------------------------------------------------------
G="$HERE/hooks/pretool-guard.sh"
# The guard sends every command to the Jev service in the background. Tests
# must not feed it, so the kill-switch file is pointed at one that always
# exists (/). The jev-shadow section below sets its own.
export JEV_SHADOW_OFF_FILE=/
# guard CMD [CWD]: deletes and git discards are decided from what is on disk
# under CWD, so cases that depend on it run against the fixture below.
guard() { jq -n --arg c "$1" --arg w "${2:-$PWD}" '{tool_input:{command:$c}, cwd:$w}' | "$G"; }
guard_is() { # cmd, expected decision, label, [cwd]
  local out d
  out=$(guard "$1" "${4:-}")
  # No output at all is the allow path — the hook stays silent and the tool runs.
  if [ -z "$out" ]; then
    d="allow"
  else
    d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo parse-error)
  fi
  if [ "$d" = "$2" ]; then ok "guard:$2:$3"; else bad "guard:$2:$3" "got '$d'"; fi
}

# Fixture outside the temp dirs (always deletable) and with no build/cache name
# in its path: a git repo holding clean, modified, untracked and ignored files,
# a clean worktree of it, and a plain directory with no git at all.
FX="$HOME/.claude-base-guardtest-$$"
mkdir -p "$FX/repo/keep" "$FX/repo/dirty" "$FX/repo/cfg" "$FX/repo/client/node_modules" "$FX/plain/src"
(
  cd "$FX/repo" && git init -q && printf 'node_modules/\n.env\n' > .gitignore &&
  echo a > keep/a && echo b > dirty/b && echo c > cfg/c && echo d > client/d &&
  echo x > client/node_modules/x && git add -A &&
  git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=t commit -qm init &&
  echo changed > dirty/b && mkdir new && echo n > new/n && echo secret > cfg/.env &&
  git worktree add -q "$FX/wt" -b wtb
) >/dev/null 2>&1
echo p > "$FX/plain/src/p"

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
# 10/20/2026: a global flag between tool and subcommand decides the same way
# as the bare form, and harmless commands with one stay allowed.
guard_is 'terraform -chdir=infra destroy'        deny  "tf-destroy-chdir"
guard_is 'helm -n prod uninstall web'            deny  "helm-uninstall-n"
guard_is 'aws --profile prod s3 rb s3://bucket'  deny  "s3-rb-profile"
guard_is 'flux --namespace x uninstall'          deny  "flux-uninstall-ns"
guard_is 'git push --force origin main'          deny  "force-push"
guard_is 'DROP DATABASE prod;'                   deny  "drop-db"
guard_is 'sudo reboot'                           deny  "reboot"
guard_is 'ssh host sudo shutdown -h now'         deny  "remote-shutdown"
guard_is 'git push --force-with-lease origin hf' allow "force-with-lease-ok"
guard_is 'cd repo && git push -f origin main'   deny  "force-push-after-cd"
guard_is 'git -C repo push --force origin main' deny  "force-push-with-C"
guard_is 'git push origin +main'                deny  "force-push-plus-refspec"
guard_is 'git push -uf origin main'             deny  "force-push-clustered-uf"
guard_is 'git --no-pager push -f origin main'   deny  "force-push-global-option"
guard_is 'git push origin feat+x'               allow "plus-in-branch-name"
guard_is "curl -d '{\"q\":\"git push --force origin main\"}' http://x" allow "force-push-text-in-payload"
guard_is 'kubectl delete pod nginx-1'            ask   "kubectl-pod"
guard_is 'terraform apply'                       ask   "tf-apply"
guard_is 'npm publish'                           ask   "npm-publish"
guard_is 'terraform -chdir=infra apply'          ask   "tf-apply-chdir"
guard_is 'cargo --locked publish'                ask   "cargo-publish-locked"
guard_is 'terraform -chdir=infra plan'           allow "tf-plan-chdir"
guard_is 'helm -n prod list'                     allow "helm-list-n"
guard_is 'npm --registry x install'              allow "npm-install-registry"
# 10/20/2026: git discards and prunes no longer ask. Each is decided from the
# repo's state, with a reason the agent can act on, so the owner is not pulled in.
guard_is "git -C $FX/repo reset --hard HEAD~1"   deny  "git-reset-dirty"
guard_is "git -C $FX/wt reset --hard"            allow "git-reset-clean"
guard_is "git -C $FX/repo stash -u && git -C $FX/repo reset --hard" allow "git-reset-after-stash"
guard_is "git -C $FX/repo clean -fd"             deny  "git-clean-untracked"
guard_is "git -C $FX/wt clean -fdx"              allow "git-clean-clean"
guard_is 'git checkout .'                        deny  "git-checkout-dot-dirty" "$FX/repo"
# 10/20/2026: `restore .`, `checkout -f`, `switch -f` and `clean --force` discard
# the same work as `reset --hard`, so they go through the same check.
guard_is 'git restore .'                         deny  "git-restore-dot-dirty"    "$FX/repo"
guard_is 'git restore --worktree .'              deny  "git-restore-worktree"    "$FX/repo"
guard_is 'git restore --source=HEAD --staged --worktree .' deny "git-restore-source-worktree" "$FX/repo"
guard_is 'git restore --staged .'                allow "git-restore-staged-only" "$FX/repo"
guard_is 'git restore .'                         allow "git-restore-clean-wt"    "$FX/wt"
guard_is "git -C $FX/wt restore ."               allow "git-restore-clean-wt-C"
guard_is "git -C $FX/repo restore ."             deny  "git-restore-dirty-C"
guard_is 'git checkout -f'                       deny  "git-checkout-force"      "$FX/repo"
guard_is 'git checkout --force'                  deny  "git-checkout-force-long" "$FX/repo"
guard_is 'git checkout -f'                       allow "git-checkout-force-clean" "$FX/wt"
guard_is 'git switch -f main'                    deny  "git-switch-force"        "$FX/repo"
guard_is 'git switch --discard-changes main'     deny  "git-switch-discard"      "$FX/repo"
guard_is 'git switch main'                       allow "git-switch-plain"        "$FX/repo"
guard_is 'git switch -f main'                    allow "git-switch-force-clean"  "$FX/wt"
guard_is 'git clean --force'                     deny  "git-clean-force-long"    "$FX/repo"
guard_is 'git clean --force -d'                  deny  "git-clean-force-d"       "$FX/repo"
guard_is 'git clean -n'                          allow "git-clean-dry"           "$FX/repo"
guard_is 'git clean --dry-run -d'                allow "git-clean-dry-long"      "$FX/repo"
guard_is 'git clean --force'                     allow "git-clean-force-clean"   "$FX/wt"
guard_is 'git stash -u && git restore .'         allow "git-restore-after-stash" "$FX/repo"
guard_is 'git stash -u && git checkout -f'       allow "git-checkout-after-stash" "$FX/repo"
guard_is 'git commit -m "explain why git restore . is risky"' allow "git-restore-in-message" "$FX/repo"
guard_is 'git branch -D old-feature'             allow "git-branch-D-reflog"
guard_is 'docker system prune -f'                allow "docker-prune-rebuildable"
guard_is 'docker system prune -a -f'             deny  "docker-prune-all-images"
guard_is 'docker volume prune'                   deny  "docker-volume-prune"
# Recursive delete. The textbook `rm -rf /` is not the case that happens;
# wiping uncommitted work is. 10/20/2026: decided from disk and git, never asked.
guard_is 'rm -rf ~'                              deny  "rm-home-bare"
guard_is 'rm -rf *'                              deny  "rm-glob-all"
guard_is 'rm -rf .'                              deny  "rm-dot"
guard_is 'rm -rf ..'                             deny  "rm-dotdot"
guard_is "rm -rf $FX/repo"                       deny  "rm-whole-repo"
guard_is "rm -rf $FX/plain"                      deny  "rm-abs-no-git"
guard_is 'rm -r --recursive /etc'                deny  "rm-abs-etc"
guard_is 'rm -rf ./src'                          deny  "rm-src-no-git"          "$FX/plain"
guard_is 'rm -rf keep'                           allow "rm-clean-tracked"       "$FX/repo"
guard_is 'rm -rf dirty'                          deny  "rm-modified"            "$FX/repo"
guard_is 'rm -rf new'                            deny  "rm-untracked"           "$FX/repo"
guard_is 'rm -rf cfg'                            deny  "rm-ignored-secret"      "$FX/repo"
guard_is 'rm -rf client'                         allow "rm-only-ignored-build"  "$FX/repo"
guard_is 'rm -rf ../wt'                          allow "rm-clean-worktree"      "$FX/repo"
guard_is 'rm -rf not-there'                      allow "rm-nonexistent"         "$FX/repo"
guard_is "cd $FX/repo && rm -rf new"             deny  "rm-after-cd"
guard_is "rm -rf $FX/repo/keep/*"                allow "rm-glob-clean"
guard_is "rm -rf $FX/plain/*"                    deny  "rm-glob-no-git"
guard_is 'rm -rf $UNSET_VAR'                     deny  "rm-unresolved-var"
guard_is "rm -rf /tmp/..$FX"                     deny  "rm-dotdot-escape"
guard_is "rm -rf $FX/plain; rm -f x"             deny  "rm-first-of-two"
guard_is 'git rm -r --cached keep'               allow "git-rm-is-not-rm"       "$FX/repo"
guard_is 'ssh host rm -rf ~/old-dir'             deny  "rm-remote-home"
guard_is 'ssh host rm -rf /tmp/scratch'          allow "rm-remote-tmp"
guard_is 'find . -name "*.py" -delete'           deny  "find-delete-no-git"     "$FX/plain"
guard_is 'find . -exec rm {} \;'                 deny  "find-exec-rm-no-git"    "$FX/plain"
guard_is 'find . -name "*.pyc" -delete'          allow "find-delete-clean"      "$FX/wt"
guard_is 'find /tmp/x -name "*.o" -delete'       allow "find-delete-tmp"
# False positives that prompted the owner on 10/20/2026.
guard_is "$(printf 'rm -rf /tmp/x\nls src')"     allow "rm-newline-ends-command" "$FX/plain"
guard_is 'S=/private/tmp/x; rm -rf $S/wt; ls'    allow "rm-resolved-var"
guard_is 'rm -rf client/node_modules'            allow "rm-nested-node-modules"
guard_is 'rm -rf client/dist'                    allow "rm-nested-dist"
guard_is 'rm -rf /tmp/a 2>/dev/null; ls'         allow "rm-redirect"
guard_is 'grep -rn reboot /var/log/syslog'       allow "grep-reboot-is-search"
guard_is "$(printf "git commit -F - <<'EOF'\nfix: git reset --hard handling\nEOF")" allow "heredoc-message-is-data" "$FX/repo"
guard_is 'git commit -m "note: git reset --hard is gated"' allow "message-arg-is-data"   "$FX/repo"
guard_is "$(printf "cat > notes.txt <<'EOF'\nrm -rf /\nEOF")" allow "heredoc-file-is-data"
guard_is "$(printf "bash <<'EOF'\nrm -rf $FX/plain\nEOF")"   deny  "heredoc-to-shell-runs"
guard_is "ssh host git -C /srv/app reset --hard"   deny  "remote-reset"
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
guard_is 'pytest -q'                             allow "pytest"
rm -rf "$FX"

# ---- jev shadow call (fire-and-forget; never changes a decision) -------------
J="$HERE/hooks/jev-shadow.sh"
redacts() { # label, input, secret-that-must-not-survive
  local out; out=$(printf '%s' "$2" | "$J" redact)
  if [ "${out#*"$3"}" != "$out" ]; then bad "jev-redact:$1" "secret survived"
  elif [ "${out#*REDACTED}" = "$out" ]; then bad "jev-redact:$1" "no mask marker"
  else ok "jev-redact:$1"; fi
}
redacts ghp        "export GH=ghp_$(printf 'a%.0s' $(seq 36))"                    "ghp_aaaa"
redacts github_pat "git clone https://github_pat_$(printf 'B%.0s' $(seq 30))@x/y" "github_pat_BBBB"
redacts hf         "huggingface-cli login --token hf_$(printf 'c%.0s' $(seq 34))" "hf_cccc"
redacts sk         "ANTHROPIC=sk-ant-api03-$(printf 'd%.0s' $(seq 30)) claude"    "sk-ant-api03-dddd"
redacts akia       "aws configure set aws_access_key_id AKIAABCDEFGHIJKLMNOP"     "AKIAABCDEFGHIJKLMNOP"
redacts xox        "curl -d token=xoxb-1234567890-abcdefghij https://slack.com"   "xoxb-1234567890"
redacts bearer     "curl -H 'Authorization: Bearer eyJhbGciOi.abcdef.ghijkl' x"   "eyJhbGciOi"
redacts password   "mysql -u root --password=hunter2hunter2 db"                   "hunter2hunter2"
redacts token      "TOKEN=abc123xyz789 ./run.sh"                                  "abc123xyz789"
redacts secret     "export CLIENT_SECRET='s3cr3t value here'"                     "s3cr3t value"
redacts pem        "$(printf 'echo "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\nQUJDREVGRw==\n-----END RSA PRIVATE KEY-----" > k.pem')" "MIIEowIBAAKC"
redacts hex        "echo $(printf '0123456789abcdef%.0s' 1 2 3)"                  "0123456789abcdef0123456789abcdef0"
redacts base64     "echo Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MGFiY2RlZg | base64 -d"    "Zm9vYmFyQmF6UXV4MTIzNDU2"
redacts url-cred   "git clone https://user:p4ssw0rd@github.com/x/y.git"           "p4ssw0rd"
untouched() { local out; out=$(printf '%s' "$1" | "$J" redact); if [ "$out" = "$1" ]; then ok "jev-redact:keeps:$2"; else bad "jev-redact:keeps:$2" "got '$out'"; fi; }
untouched 'git push --set-upstream origin bugfix/token-count'      "branch-named-token"
untouched 'rm -rf /Users/jgavinray/dev/mission-control/src/components' "long-path"
untouched 'docker compose up -d --build'                           "plain"

# A stub service records what it is sent. Port is chosen by the OS.
JT=$(mktemp -d); JPORT_FILE="$JT/port"; JBODY="$JT/body"
python3 - "$JPORT_FILE" "$JBODY" "${JEV_STUB_DELAY:-0}" <<'PYEOF' &
import http.server, sys, time
portfile, bodyfile, delay = sys.argv[1], sys.argv[2], float(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        data = self.rfile.read(n)
        with open(bodyfile, "ab") as f: f.write(data + b"\n")
        time.sleep(delay)
        try:
            self.send_response(200); self.send_header("content-length", "2"); self.end_headers(); self.wfile.write(b"{}")
        except OSError: pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
JSTUB=$!
for _ in $(seq 50); do [ -s "$JPORT_FILE" ] && break; sleep 0.1; done
JURL="http://127.0.0.1:$(cat "$JPORT_FILE")"
OFFF="$JT/off"   # kill-switch file used by these tests (absent = shadow on)

waitbody() { for _ in $(seq 60); do [ -s "$JBODY" ] && return 0; sleep 0.1; done; return 1; }
# decision_of CMD -> allow|deny|ask, with the shadow call ON, pointed at $URL
decision_with() { # url, cmd
  local out
  out=$(jq -n --arg c "$2" '{tool_input:{command:$c}, cwd:"/tmp"}' | JEV_SHADOW_OFF_FILE="$OFFF" JEV_SHADOW_URL="$1" "$G")
  if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}

# 1. A reachable service gets the redacted command, and only that.
: > "$JBODY"
TOKEN="ghp_$(printf 'Z%.0s' $(seq 36))"
d=$(decision_with "$JURL" "curl -H 'Authorization: Bearer $TOKEN' https://api.github.com/user")
if [ "$d" = allow ]; then ok "jev-shadow:decision-unchanged-allow"; else bad "jev-shadow:decision-unchanged-allow" "got $d"; fi
if waitbody; then ok "jev-shadow:request-arrives"; else bad "jev-shadow:request-arrives" "nothing within 6s"; fi
T "jev-shadow:body-is-valid-jev-request" bash -c "head -1 '$JBODY' | jq -e '.questions.verdict.type == \"choice\" and (.questions.verdict.criteria | keys | length) == 5 and (.state | contains(\"api.github.com\"))'"
TN "jev-shadow:raw-secret-never-sent" grep -q "ZZZZZZZZZZ" "$JBODY"
T  "jev-shadow:mask-marker-sent" grep -q "REDACTED" "$JBODY"

# 2. Decisions are unchanged whether the service is up, down, or black-holed.
for pair in "up|$JURL" "refused|http://127.0.0.1:9" "blackhole|http://192.0.2.1:9"; do
  name=${pair%%|*}; url=${pair#*|}
  d=$(JEV_SHADOW_TIMEOUT=2 decision_with "$url" 'git push --force origin main')
  if [ "$d" = deny ]; then ok "jev-shadow:deny-kept:$name"; else bad "jev-shadow:deny-kept:$name" "got $d"; fi
  d=$(JEV_SHADOW_TIMEOUT=2 decision_with "$url" 'npm publish')
  if [ "$d" = ask ]; then ok "jev-shadow:ask-kept:$name"; else bad "jev-shadow:ask-kept:$name" "got $d"; fi
done

# 3. Speed: the hook returns without waiting, and the shadow call adds under
# 20 ms (median of 21 runs, alternating, against an unreachable black hole
# with a 5 s timeout, so a hook that waited would add seconds).
JEV_TIMING=$(python3 - "$G" "$OFFF" <<'PYEOF'
import json, os, statistics, subprocess, sys, time
guard, offf = sys.argv[1], sys.argv[2]
payload = json.dumps({"tool_input": {"command": "ls -la"}, "cwd": "/tmp"}).encode()
def run(shadow_on):
    env = dict(os.environ, JEV_SHADOW_URL="http://192.0.2.1:9", JEV_SHADOW_TIMEOUT="5",
               JEV_SHADOW_OFF_FILE=offf if shadow_on else "/")
    t = time.perf_counter()
    subprocess.run([guard], input=payload, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    return (time.perf_counter() - t) * 1000
run(True); run(False)
on, off = [], []
for _ in range(21):
    on.append(run(True)); off.append(run(False))
print("%.1f %.1f" % (statistics.median(on), statistics.median(off)))
PYEOF
)
read -r JON JOFF <<<"$JEV_TIMING"
JDIFF=$(python3 -c "print(round($JON - $JOFF, 1))")
if python3 -c "import sys; sys.exit(0 if $JON - $JOFF < 20 else 1)"; then ok "jev-shadow:adds-under-20ms (on ${JON}ms, off ${JOFF}ms, +${JDIFF}ms)"; else bad "jev-shadow:adds-under-20ms" "on ${JON}ms off ${JOFF}ms"; fi

# 4. Kill switch: with the file present, nothing is sent.
: > "$JBODY"; touch "$OFFF"
jq -n '{tool_input:{command:"ls"}, cwd:"/tmp"}' | JEV_SHADOW_OFF_FILE="$OFFF" JEV_SHADOW_URL="$JURL" "$G" >/dev/null
sleep 1.5
if [ -s "$JBODY" ]; then bad "jev-shadow:kill-switch" "request was sent"; else ok "jev-shadow:kill-switch"; fi
rm -f "$OFFF"

kill "$JSTUB" 2>/dev/null; wait "$JSTUB" 2>/dev/null
rm -rf "$JT"

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
  BEFORE=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  '$HERE/install.sh' --dry-run >/dev/null
  AFTER=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  [ \"\$BEFORE\" = \"\$AFTER\" ]"

rm -rf "$W" "$GW" "$R" "$R2" "${R3:-}" "$R4" "$R5" "$R6" "$R7" "$R8" 2>/dev/null
rm -f "$TMP/claude-base-edited-basetest-"* "$TMP/claude-base-stopgate-basetest-"* 2>/dev/null


# ---- project-level harness takes precedence ---------------------------------
# Hooks from ~/.claude and <repo>/.claude both run. A repo that carries its own
# harness must not get two gates.
PW=$(mktemp -d); mkdir -p "$PW/.claude"
printf '#!/usr/bin/env bash\necho OWNFAIL\nexit 1\n' > "$PW/.claude/verify.sh"; chmod +x "$PW/.claude/verify.sh"
SIDP="basetest-proj-$$"; : > "$TMP/claude-base-edited-$SIDP"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}' > "$PW/.claude/settings.json"
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SIDP" "$PW" | "$S")
if [ -z "$OUT" ]; then ok "defer:stopgate-yields-to-project"; else bad "defer:stopgate-yields-to-project" "emitted: $OUT"; fi
printf '{"hooks":{"PreToolUse":[]}}' > "$PW/.claude/settings.json"
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SIDP" "$PW" | "$S")
T "defer:stopgate-runs-without-project-stop" bash -c "printf '%s' '$OUT' | jq -e '.decision == \"block\"'"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]}}' > "$PW/.claude/settings.json"
SCOUT=$(printf '{"cwd":"%s"}' "$PW" | "$SC" 2>/dev/null)
if [ -z "$SCOUT" ]; then ok "defer:sessctx-yields-to-project"; else bad "defer:sessctx-yields-to-project"; fi
rm -rf "$PW"; rm -f "$TMP/claude-base-edited-$SIDP" "$TMP/claude-base-stopgate-$SIDP"

# ---- baseline: gate on regression, not absolute green -----------------------
BR=$(mkrepo)
printf '#!/usr/bin/env bash\nif [ 1 ; then\n' > "$BR/legacy.sh"
T  "baseline:red-before-baseline" bash -c "! (cd '$BR' && ./.claude/verify.sh)"
printf 'sh-syntax\n' > "$BR/.claude/baseline"
T  "baseline:preexisting-not-blocking" bash -c "cd '$BR' && ./.claude/verify.sh"
T  "baseline:reports-preexisting" bash -c "cd '$BR' && ./.claude/verify.sh | grep -q 'still failing from baseline'"
printf 'a: [1, 2\n' > "$BR/bad.yaml"
TN "baseline:new-failure-still-blocks" bash -c "cd '$BR' && ./.claude/verify.sh"
printf 'a: 1\n' > "$BR/bad.yaml"
printf '#!/usr/bin/env bash\necho ok\n' > "$BR/legacy.sh"
T  "baseline:flags-stale-entry" bash -c "cd '$BR' && ./.claude/verify.sh | grep -q 'NOW PASSING'"
T  "audit:reports-all-not-just-first" bash -c "cd '$BR' && ./.claude/verify.sh --audit | grep -q '^PASS '"
rm -rf "$BR"

# ---- untracked-but-not-ignored files are still checked ----------------------
UR=$(mkrepo)
printf 'a: [1, 2\n' > "$UR/fresh.yaml"
TN "discovery:untracked-file-checked" bash -c "cd '$UR' && ./.claude/verify.sh"
rm -rf "$UR"

# The harness's own .claude/ must never be treated as repo code, or every repo
# would detect sh-syntax from verify.sh itself and no repo could report INERT.
XR=$(mkrepo)
T "discovery:excludes-dot-claude" bash -c "cd '$XR' && ./.claude/verify.sh --list | grep -qx NONE"
rm -rf "$XR"


# ---- determinism: pinning, timeouts, no silent truncation -------------------
PR2=$(mkrepo)
printf '#!/usr/bin/env bash\necho ok\n' > "$PR2/a.sh"
printf 'need-a-tool-that-is-not-here\n' > "$PR2/.claude/expected-checks"
TN "pin:missing-expected-check-fails" bash -c "cd '$PR2' && ./.claude/verify.sh"
T  "pin:names-the-missing-check" bash -c "cd '$PR2' && ./.claude/verify.sh 2>&1 | grep -q 'EXPECTED CHECK'"
(cd "$PR2" && ./.claude/verify.sh --list | sort) > "$PR2/.claude/expected-checks"
T  "pin:satisfied-passes" bash -c "cd '$PR2' && ./.claude/verify.sh"
rm -rf "$PR2"

TO=$(mkrepo)
printf '#!/usr/bin/env bash\nsleep 30\n' > "$TO/.claude/checks.sh"; chmod +x "$TO/.claude/checks.sh"
if [ -n "$(command -v timeout || command -v gtimeout || true)" ]; then
  TN "timeout:hung-check-fails" bash -c "cd '$TO' && CLAUDE_BASE_CHECK_TIMEOUT=1 ./.claude/verify.sh"
  T  "timeout:names-the-check" bash -c "cd '$TO' && CLAUDE_BASE_CHECK_TIMEOUT=1 ./.claude/verify.sh 2>&1 | grep -q 'TIMED OUT'"
else
  echo "SKIP timeout:* (no timeout/gtimeout)"
fi
rm -rf "$TO"

T "verify:no-silent-truncation" bash -c "! grep -v '^[[:space:]]*#' '$HERE/verify/verify.sh' | grep -q 'head -500'"
T "verify:kubeconform-sorted" bash -c "grep -q 'sort' '$HERE/verify/verify.sh'"
T "verify:locale-pinned" grep -q 'export LC_ALL=C' "$HERE/verify/verify.sh"

# ---- uninstall is exact and reversible --------------------------------------
T "uninstall:executable" test -x "$HERE/uninstall.sh"
T "uninstall:dry-run-writes-nothing" bash -c "
  B=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  '$HERE/uninstall.sh' --dry-run >/dev/null 2>&1
  A=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  [ \"\$B\" = \"\$A\" ]"
T "uninstall:keeps-attribution" grep -q "attribution.*left in settings.json\|NOT removed" "$HERE/uninstall.sh"
T "ci:template-runs-same-verifier" grep -q './.claude/verify.sh' "$HERE/templates/ci.yml"

echo "----"
if [ "$FAILURES" -eq 0 ]; then echo "base-test: all green"; else echo "base-test: $FAILURES failure(s)"; fi
exit $((FAILURES > 0))
