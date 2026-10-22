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

for a in verifier code-reviewer qa-tester doc-manager; do
  T "agent:$a-frontmatter" bash -c "head -1 '$HERE/agents/$a.md' | grep -q -- '---'"
  T "agent:$a-name" bash -c "grep -q '^name: $a\$' '$HERE/agents/$a.md'"
done
T "settings:no-attribution" bash -c "jq -e '.attribution.commit == \"\" and .attribution.pr == \"\"' '$HERE/settings.json'"
T "settings:deny-rm-root-exact" bash -c "jq -e '.permissions.deny | index(\"Bash(rm -rf /)\") != null and index(\"Bash(rm -rf /*)\") == null' '$HERE/settings.json'"
T "license:gplv2-present" bash -c "grep -q 'GNU GENERAL PUBLIC LICENSE' '$HERE/LICENSE' && grep -q 'Version 2, June 1991' '$HERE/LICENSE'"
T "license:readme-states-gplv2" grep -q "GNU General Public License" "$HERE/README.md"
T "readme:documents-baseline" grep -q "baseline" "$HERE/README.md"
T "rules:no-coauthored-rule" grep -q "no attribution trailer" "$HERE/CLAUDE.md"
T "rules:global-at-most-60-lines" bash -c "[ \$(wc -l < '$HERE/CLAUDE.md') -le 60 ]"

# ---- pretool-guard -----------------------------------------------------------
G="$HERE/hooks/pretool-guard.sh"
# The guard sends every command to the Jev service in the background. Tests
# must not feed it, so the kill-switch file is pointed at one that always
# exists (/). The jev-shadow section below sets its own.
export JEV_SHADOW_OFF_FILE=/
export SCOPE_CHECK_OFF_FILE=/   # the scope section below sets its own
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
# 10/21/2026: settings.json denies only the exact `rm -rf /` (the old `rm -rf /*`
# rule was a prefix wildcard that refused every absolute-path delete). These
# cases are what the narrowed static rule used to catch; the guard must hold them.
guard_is 'rm -rf /*'                             deny  "rm-root-glob"
guard_is 'rm -rf / --no-preserve-root'           deny  "rm-root-no-preserve"
guard_is "rm -rf $HOME"                          deny  "rm-home-abs"
guard_is 'rm -rf $HOME/dev'                      deny  "rm-home-subdir-var"
guard_is "rm -rf $HOME/dev"                      deny  "rm-home-subdir-abs"
guard_is 'rm -rf /usr'                           deny  "rm-abs-usr"
guard_is 'rm -rf /System'                        deny  "rm-abs-system"
guard_is 'sudo rm -rf /var'                      deny  "rm-sudo-var"
guard_is "ssh host 'rm -rf /'"                   deny  "rm-remote-root-quoted"
guard_is 'ssh host rm -rf /'                     deny  "rm-remote-root"
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

# 10/21/2026: the session may delete its own scratch whole, with no git check:
# /tmp, /private/tmp, $TMPDIR, /private/var/folders/*/*/T, Claude scratchpads,
# ~/.cache/runner/work, and paths listed in ~/.claude/guard-ephemeral. Anything
# else keeps its old answer. HOME is pointed at a fake home inside the fixture
# so the cases do not depend on the real one.
FH="$FX/home"
mkdir -p "$FH/dev/proj" "$FH/.cache/runner/work/wt1" "$FH/.claude" "$FX/odd/raw" "$FX/odd/keep" "$FX/tmpd/sub"
echo p > "$FH/dev/proj/f"; echo r > "$FX/odd/raw/f"; echo k > "$FX/odd/keep/f"
ST="/tmp/claude-base-guardtest-$$"
mkdir -p "$ST/real" "/private/tmp/claude-base-guardtest-sp-$$/scratchpad/x"
ln -s "$FH/dev" "$ST/lnk-dev"; ln -s "$FH" "$ST/lnk-home"; ln -s "$ST/real" "$ST/lnk-real"
hg_is() { HOME="$FH" guard_is "$@"; }   # cmd, decision, label, [cwd]
hg_is "rm -rf $ST/real"                                  allow "rm-tmp-dir"
hg_is "rm -rf /private/tmp/claude-base-guardtest-sp-$$/scratchpad/x" allow "rm-claude-scratchpad"
hg_is "rm -rf $ST/lnk-real"                              allow "rm-tmp-symlink-to-tmp"
hg_is 'rm -rf ~/.cache/runner/work/wt1'                  allow "rm-runner-worktree"
hg_is 'rm -rf ~/.cache/runner/work'                      deny  "rm-runner-work-root-itself"
hg_is 'rm -rf ~'                                         deny  "rm-home-fake"
hg_is 'rm -rf ~/dev'                                     deny  "rm-home-dev"
hg_is "rm -rf $FH"                                       deny  "rm-home-literal"
hg_is "rm -rf /tmp/../$FH/dev/proj"                      deny  "rm-tmp-dotdot-into-home"
hg_is "rm -rf $ST/lnk-dev/proj"                          deny  "rm-tmp-symlink-into-home-child"
hg_is "rm -rf $ST/lnk-dev"                               deny  "rm-tmp-symlink-to-home-dir"
hg_is "rm -rf $ST/lnk-home"                              deny  "rm-tmp-symlink-to-home"
hg_is "rm -rf $ST/lnk-home/dev"                          deny  "rm-tmp-symlink-via-home"
TMPDIR= hg_is 'rm -rf $TMPDIR/sub'                       deny  "rm-tmpdir-unset"
TMPDIR="$FX/tmpd/" hg_is 'rm -rf $TMPDIR/sub'            allow "rm-tmpdir-var"
TMPDIR="$FX/tmpd/" hg_is 'rm -rf ${TMPDIR}/sub'          allow "rm-tmpdir-braced"
TMPDIR="$FX/tmpd" hg_is 'rm -rf $TMPDIR'                 deny  "rm-tmpdir-itself"
TMPDIR="$FH" hg_is 'rm -rf $TMPDIR/dev'                  deny  "rm-tmpdir-is-home"
hg_is "rm -rf /private/var/folders/aa/bb/T/claude-base-guardtest-none-$$" allow "rm-var-folders-T"
hg_is "rm -rf $FX/odd/raw"                               deny  "rm-unlisted-path"
printf '# scratch the session made\n%s\n   %s/   \n~/dev/proj/../elsewhere\n' "$FX/odd/raw" "$FX/odd/keep" > "$FH/.claude/guard-ephemeral"
hg_is "rm -rf $FX/odd/raw"                               allow "rm-listed-exact"
hg_is "rm -rf $FX/odd/raw/f"                             allow "rm-listed-below"
hg_is "rm -rf $FX/odd/keep"                              allow "rm-listed-trimmed"
hg_is "rm -rf $FX/odd"                                   deny  "rm-listed-parent-not-allowed"
mkdir -p "$FX/odd/raw-other"; echo o > "$FX/odd/raw-other/f"
hg_is "rm -rf $FX/odd/raw-other"                         deny  "rm-listed-prefix-is-whole-component"
printf '/\n%s\n' "$FH" > "$FH/.claude/guard-ephemeral"
hg_is "rm -rf $FH/dev"                                   deny  "rm-list-line-covering-home-ignored"
hg_is "rm -rf $FX/plain"                                 deny  "rm-list-root-ignored"
hg_is "ssh host rm -rf $FH/.cache/runner/work/wt1"       deny  "rm-remote-runner-work"
rm -rf "$ST" "/private/tmp/claude-base-guardtest-sp-$$"
# 10/21/2026: `mysql-db:NAME` lines in guard-ephemeral allow DROP DATABASE for
# exactly that name (direct, sudo mysql -e, ssh), one statement. Else denied.
printf '# test databases the session made\nmysql-db:acore_auth_test\nmysql-db:acore_world_test  # trailing note\n' > "$FH/.claude/guard-ephemeral"
hg_is 'mysql -e "DROP DATABASE acore_auth_test"'                          allow "mysqldrop-listed"
hg_is 'sudo mysql -e "drop database if exists `acore_world_test`;"'        allow "mysqldrop-listed-backticks-ifexists"
hg_is "ssh jgavinray@192.168.0.44 'sudo mysql -e \"DROP DATABASE acore_auth_test\"'" allow "mysqldrop-listed-over-ssh"
hg_is "ssh jgavinray@192.168.0.44 'sudo mysql -e \"DROP DATABASE IF EXISTS acore_world_test\"'" allow "mysqldrop-listed-over-ssh-ifexists"
hg_is 'mysql -e "DROP DATABASE acore_characters_test"'                    deny  "mysqldrop-unlisted"
hg_is 'mysql -e "DROP DATABASE acore_auth"'                               deny  "mysqldrop-acore_auth"
hg_is 'mysql -e "DROP DATABASE acore_world"'                              deny  "mysqldrop-acore_world"
hg_is 'mysql -e "DROP DATABASE acore_%"'                                  deny  "mysqldrop-wildcard"
hg_is 'mysql -e "DROP DATABASE acore_auth_test%"'                         deny  "mysqldrop-wildcard-suffix"
hg_is 'mysql -e "DROP DATABASE acore_auth_test; DROP DATABASE acore_auth"' deny  "mysqldrop-second-statement-unlisted"
hg_is 'mysql -e "DROP DATABASE acore_auth_test; SELECT 1"'                deny  "mysqldrop-second-statement-select"
hg_is 'mysql -e "SELECT 1; DROP DATABASE acore_auth_test"'                deny  "mysqldrop-first-statement-other"
hg_is 'mysql -e "DROP DATABASE acore_auth_test; DROP DATABASE acore_world_test"' deny "mysqldrop-two-listed-statements"
hg_is 'mysql -e "DROP DATABASE acore_auth_testx"'                         deny  "mysqldrop-name-prefix-only"
hg_is 'mysql -e "DROP SCHEMA acore_characters_test"'                      deny  "mysqldrop-schema-unlisted"
hg_is 'mysql -e "TRUNCATE TABLE acore_auth_test.account"'                 deny  "mysqldrop-truncate-still-denied"
rm -f "$FH/.claude/guard-ephemeral"
hg_is 'mysql -e "DROP DATABASE acore_auth_test"'                          deny  "mysqldrop-no-list-file"
printf 'mysql-db: acore_auth_test\n/\n' > "$FH/.claude/guard-ephemeral"
hg_is 'mysql -e "DROP DATABASE acore_auth_test"'                          allow "mysqldrop-space-after-colon"
rm -f "$FH/.claude/guard-ephemeral"
# 10/21/2026: `host:<ip-or-alias>:<abs path>` lines in guard-ephemeral allow
# recursive deletes of that path (and below) over ssh, for that host only.
printf 'host:192.168.0.44:/home/azeroth/ac-build\nhost:hyper01:/home/azeroth/ac-stage/\nhost:192.168.0.44:/home/azeroth\nhost:192.168.0.44:/etc\nhost:192.168.0.44:/\n' > "$FH/.claude/guard-ephemeral"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build'"        allow "hostrm-listed"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build/sub/x'"  allow "hostrm-listed-below"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build/*'"      allow "hostrm-listed-glob-below"
hg_is "ssh jgavinray@192.168.0.44 sudo rm -rf /home/azeroth/ac-build"     allow "hostrm-listed-sudo"
hg_is "ssh -o StrictHostKeyChecking=no -i /k -p 22 jgavinray@192.168.0.44 'sudo rm -rf /home/azeroth/ac-build'" allow "hostrm-listed-ssh-options"
hg_is "ssh hyper01 'rm -rf /home/azeroth/ac-stage'"                       allow "hostrm-listed-alias"
hg_is "ssh 192.168.0.44 'rm -rf /home/azeroth/ac-stage'"                  deny  "hostrm-alias-is-not-its-ip"
hg_is "ssh hyper01 'rm -rf /home/azeroth/ac-build'"                       deny  "hostrm-ip-line-is-not-the-alias"
hg_is "ssh jgavinray@192.168.0.43 'rm -rf /home/azeroth/ac-build'"        deny  "hostrm-other-host"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-other'"        deny  "hostrm-unlisted-path"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build-old'"    deny  "hostrm-prefix-is-whole-component"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-*'"            deny  "hostrm-glob-above-listed"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build/../ac-other'" deny "hostrm-dotdot-escape"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf ac-build'"                      deny  "hostrm-relative"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth'"                 deny  "hostrm-listed-home-line-ignored"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/other'"           deny  "hostrm-listed-home-line-covers-nothing"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /etc/foo'"                      deny  "hostrm-listed-system-line-ignored"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /'"                             deny  "hostrm-root"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build /home/azeroth/ac-other'" deny "hostrm-one-target-unlisted"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build \$X'"    deny  "hostrm-variable-target"
rm -f "$FH/.claude/guard-ephemeral"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/ac-build'"        deny  "hostrm-no-list-file"
# 10/21/2026: a regenerable NAME (dist, venv, build, ...) is not enough. Locally
# nothing may be running in it and it may hold no *.conf or etc/; over ssh the
# name alone allows nothing (a live AzerothCore env/dist was one rm away).
mkdir -p "$FX/live/dist/bin" "$FX/confdist/dist/etc" "$FX/plainbuild/build/out" "$FX/venvlive/venv/bin"
echo x > "$FX/confdist/dist/etc/x.conf"; echo y > "$FX/plainbuild/build/out/o.o"
(cd "$FX/live/dist/bin" && exec /bin/sleep 300) & LIVE1=$!
(cd "$FX/venvlive/venv" && exec /bin/sleep 300) & LIVE2=$!
sleep 0.5
guard_is "rm -rf $FX/live/dist"                  deny  "regen-dist-with-running-process"
guard_is "rm -rf $FX/venvlive/venv"              deny  "regen-venv-with-running-cwd"
guard_is "rm -rf $FX/confdist/dist"              deny  "regen-dist-with-etc-conf"
guard_is "rm -rf $FX/plainbuild/build"           allow "regen-plain-build-dir"
guard_is "cd $FX/plainbuild && rm -rf build"     allow "regen-plain-build-dir-relative"
kill "$LIVE1" "$LIVE2" 2>/dev/null; wait "$LIVE1" "$LIVE2" 2>/dev/null
guard_is "rm -rf $FX/live/dist"                  allow "regen-dist-after-process-exits"
guard_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/azerothcore-wotlk/env/dist'" deny "regen-remote-env-dist"
guard_is "ssh hyper01 'rm -rf node_modules'"     deny  "regen-remote-relative-node_modules"
guard_is "ssh hyper01 'rm -rf /tmp/proj/build'"  allow "regen-remote-tmp-build"
printf 'host:192.168.0.44:/home/azeroth/azerothcore-wotlk/env/dist\n' > "$FH/.claude/guard-ephemeral"
hg_is "ssh jgavinray@192.168.0.44 'rm -rf /home/azeroth/azerothcore-wotlk/env/dist'" allow "regen-remote-env-dist-listed"
hg_is "ssh jgavinray@192.168.0.44 'sudo rm -rf /home/azeroth/azerothcore-wotlk/env/dist/etc'" allow "regen-remote-env-dist-listed-below"
hg_is "ssh jgavinray@192.168.0.43 'rm -rf /home/azeroth/azerothcore-wotlk/env/dist'" deny "regen-remote-listed-other-host"
rm -f "$FH/.claude/guard-ephemeral"
guard_is 'rm -f server.log'                      allow "rm-nonrecursive-with-r-in-name"
guard_is 'rm -f config.json'                     allow "rm-single-file"
guard_is 'ls -la'                                allow "ls"
guard_is 'kubectl get pods -A'                   allow "kubectl-get"
guard_is 'git status'                            allow "git-status"
guard_is 'pytest -q'                             allow "pytest"
rm -rf "$FX"

# ---- scope-check (10/21/2026): did the agent start what it is about to signal? -
# Enforced without a model: signals to processes this session did not start,
# and NVIDIA/driver/reboot commands aimed at hyper03. In the same class list but
# only LOGGED (judge in the background, never blocks): service control,
# overwrites outside the workspace, ssh state changes, anything else on hyper03.
SC="$HERE/hooks/scope-check.sh"
T "syntax:scope-check.sh" bash -n "$SC"
SCT="$TMP/scope-test-$$"; mkdir -p "$SCT"
SLOG="$SCT/log"; SBODY="$SCT/body"; SPROB="$SCT/prob"; SPORTF="$SCT/port"; SENF="$SCT/enforce-flag"
SFX="$HOME/.claude-base-scopetest-$$"; mkdir -p "$SFX/work" "$SFX/shared"; echo held > "$SFX/shared/hold"
SSP="/private/tmp/claude-scopetest-$$/proj/sid-$$/scratchpad"; mkdir -p "$SSP"
echo 0.05 > "$SPROB"
python3 - "$SPORTF" "$SBODY" "$SPROB" <<'PYEOF' &
import sys, json, http.server
portf, bodyf, probf = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0)); b = self.rfile.read(n)
        open(bodyf, 'ab').write(b + b'\n')
        p = float(open(probf).read().strip())
        out = json.dumps({"model": "stub", "answers": {"verdict": {"type": "choice", "choice": "x", "probabilities": {
            "safe_own_work": (1 - p) / 2, "safe_shared_ok": (1 - p) / 2, "disturbs_others_work": p}}}}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(portf, 'w').write(str(s.server_port)); s.serve_forever()
PYEOF
SSRV=$!
for _ in $(seq 1 50); do [ -s "$SPORTF" ] && break; sleep 0.1; done
SURL="http://127.0.0.1:$(cat "$SPORTF" 2>/dev/null)"

# sc CMD [CWD] [SESSION_ID]: run scope-check in hook mode; prints deny|allow
sc_env() { SCOPE_CHECK_SESSION_PID=$$ SCOPE_CHECK_OFF_FILE="$SCT/no-off" SCOPE_CHECK_LOG="$SLOG" SCOPE_CHECK_URL="${SC_URL:-$SURL}" \
  SCOPE_CHECK_JEV_ENFORCE_FILE="${SC_ENF:-$SCT/no-enforce}" SCOPE_CHECK_OWN_FILE="$SCT/no-own" SCOPE_CHECK_TIMEOUT=2 SCOPE_CHECK_SHADOW_TIMEOUT=3 "$@"; }
sc_out() { jq -n --arg c "$1" --arg w "${2:-$SFX/work}" --arg s "${3:-}" '{tool_input:{command:$c}, cwd:$w, session_id:$s}' | sc_env "$SC" ${SC_MODE:-hook}; }
sc_is() { # cmd, expected, label, [cwd], [session]
  local out d
  out=$(sc_out "$1" "${4:-}" "${5:-}")
  if [ -z "$out" ]; then d=allow; else d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo parse-error); fi
  if [ "$d" = "$2" ]; then ok "scope:$2:$3"; else bad "scope:$2:$3" "got '$d'"; fi
}
waitfor() { local i; for i in $(seq 1 60); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }

# Processes: a decoy that is not a child of this test (reparented to init, the
# way another session's shell or a daemon is) and one that is.
( (bash -c 'sleep 300; :' "scopetest-$$-server.py" >/dev/null 2>&1 &) )
bash -c 'sleep 301; :' "scopetest-$$-own.py" >/dev/null 2>&1 & OWNPID=$!
sleep 0.5
DECOY=$(pgrep -f "scopetest-$$-server.py" | head -1)
if [ -n "$DECOY" ]; then ok "scope:fixture-decoy-running"; else bad "scope:fixture-decoy-running" "no decoy process"; fi

sc_is "kill $DECOY"                              deny  "kill-other-process"
sc_is "kill -STOP $DECOY"                        deny  "kill-stop-other-process"
sc_is "kill -9 $DECOY $OWNPID"                   deny  "kill-one-of-two-is-foreign"
sc_is "kill $OWNPID"                             allow "kill-own-child"
sc_is "kill -STOP $OWNPID"                       allow "kill-stop-own-child"
sc_is 'sleep 1000 & kill $!'                     allow "kill-dollar-bang"
sc_is 'kill -0 '"$DECOY"                         allow "kill-0-is-only-a-check"
sc_is 'kill -l'                                  allow "kill-l-lists-signals"
sc_is "kill 99999999"                            allow "kill-no-such-process"
sc_is "pkill -f scopetest-$$-server.py"          deny  "pkill-f-hits-other-process"
sc_is "pkill -f scopetest-$$-own.py"             allow "pkill-f-own-child-only"
sc_is "pkill -f scopetest-$$-no-such-zzz"        allow "pkill-f-no-match"
sc_is "killall scopetest-$$-none"                allow "killall-no-match"
sc_is 'for p in $(pgrep -f scopetest); do kill -STOP $p; done' deny "kill-unresolvable-target"
sc_is 'kill $(pgrep -f scopetest)'               deny  "kill-command-substitution-of-pgrep"
sc_is 'pgrep -f scopetest | xargs kill -9'       deny  "kill-xargs-from-pgrep"
# a pid file this session wrote, under its scratchpad
echo "$DECOY" > "$SSP/srv.pid"
sc_is "kill $DECOY"                              allow "kill-pid-in-session-pidfile" "$SFX/work" "sid-$$"
sc_is "kill $DECOY"                              deny  "kill-pid-in-other-sessions-pidfile" "$SFX/work" "sid-other-$$"
sc_is "kill \$(cat $SSP/srv.pid)"                allow "kill-cat-pidfile-in-scratch"
sc_is "kill \$(cat $SFX/shared/hold)"            deny  "kill-cat-file-outside-scratch"
sc_is "ssh hyper01 'kill 4242'"                  allow "remote-kill-is-logged-not-enforced"
# Tonight's three incidents
sc_is "pkill -f scopetest-$$-server.py"          deny  "incident-pkill-f-server.py-hit-another-session"
sc_is 'for p in $(pgrep -f /Users/x/scopetest); do kill -STOP $p; done' deny "incident-sigstop-of-sessions-matched-by-path"
rm -f "$SLOG" "$SBODY"
sc_is "while true; do touch $SFX/shared/hold; sleep 30; done" allow "incident-touch-loop-on-hold-file-is-not-blocked"
if waitfor "$SBODY"; then ok "scope:incident-touch-loop-reaches-the-judge"; else bad "scope:incident-touch-loop-reaches-the-judge" "no request within 6s"; fi
T "scope:judge-request-model" bash -c "head -1 '$SBODY' | jq -e '.model == \"jev-scope-check\" and (.questions.verdict.criteria | keys == [\"disturbs_others_work\",\"safe_own_work\",\"safe_shared_ok\"])'"
T "scope:judge-request-names-the-file" bash -c "head -1 '$SBODY' | jq -e '.state | contains(\"hold\") and contains(\"minutes ago\")'"
waitfor "$SLOG" && sleep 0.3
T "scope:log-only-decision-logged" bash -c "tail -1 '$SLOG' | jq -e '.decision == \"would-allow\" and .source == \"jev-log-only\"'"
# hyper03
sc_is "ssh jgavinray@192.168.0.43 nvidia-smi"    deny  "hyper03-nvidia-smi"
sc_is "ssh 192.168.0.43 'sudo apt install nvidia-driver-550'" deny "hyper03-driver-install"
sc_is "ssh 192.168.0.43 'sudo modprobe -r nvidia'" deny "hyper03-modprobe"
sc_is "ssh 192.168.0.43 'sudo systemctl restart foo'" allow "hyper03-restart-is-logged-not-enforced"
sc_is "curl -s http://192.168.0.43:8081/health"  allow "hyper03-health-is-logged-not-enforced"
sc_is "git commit -m 'note: nvidia driver on 192.168.0.43'" allow "hyper03-in-a-commit-message"
# read-only and own-workspace commands never reach the judge (let the earlier
# background log-only calls land first)
sleep 1.5; rm -f "$SBODY"
sc_is "ls -la"                                   allow "readonly-ls"
sc_is "git status"                               allow "readonly-git-status"
sc_is "cat $SFX/shared/hold"                     allow "readonly-cat-file-outside"
sc_is "ssh hyper01 'df -h; docker ps; systemctl status x'" allow "readonly-ssh"
sc_is "echo x > $SFX/work/out.txt"               allow "write-inside-own-cwd"
sc_is "cp a.txt /tmp/scope-test-new-$$"          allow "write-to-tmp"
sc_is "echo x > $SFX/shared/newfile"             allow "new-file-cannot-clobber"
sleep 1
if [ -s "$SBODY" ]; then bad "scope:readonly-never-calls-the-judge" "a request was sent"; else ok "scope:readonly-never-calls-the-judge"; fi
# classes that do call the judge
classify_has() { # cmd, class, label
  local c; c=$(jq -n --arg c "$1" --arg w "$SFX/work" '{tool_input:{command:$c}, cwd:$w}' | sc_env "$SC" classify | jq -r '[.triggers[].class] | join(",")')
  case ",$c," in *",$2,"*) ok "scope:class:$2:$3" ;; *) bad "scope:class:$2:$3" "got '$c'" ;; esac
}
classify_has "systemctl restart nginx"           service "systemctl"
classify_has "docker stop web"                   service "docker-stop"
classify_has "brew services restart postgresql"  service "brew-services"
classify_has "launchctl unload x.plist"          service "launchctl"
classify_has "mv $SFX/shared/hold /tmp/hold"     file    "mv-away-from-outside"
classify_has "cp a.txt $SFX/shared/hold"         file    "cp-over-outside-file"
classify_has "echo x > $SFX/shared/hold"         file    "redirect-over-outside-file"
classify_has "echo x | tee $SFX/shared/hold"     file    "tee-over-outside-file"
classify_has "sed -i s/a/b/ $SFX/shared/hold"    file    "sed-i-outside-file"
classify_has "ssh hyper01 'systemctl restart x'" service "ssh-systemctl"
classify_has "ssh hyper01 'cd /srv/app && git pull'" remote "ssh-git-pull"
classify_has "ssh hyper01 'echo x > /etc/motd'"  file    "ssh-write-outside-tmp"
classify_has "ssh hyper01 'kill 4242'"           signal  "ssh-kill"
classify_has "curl http://192.168.0.43:8081/v1/models" hyper03 "hyper03-curl"
# Enforcing mode (only with the flag file): the judge decides
touch "$SENF"; export SC_ENF="$SENF"
echo 0.90 > "$SPROB"; sc_is "cp a.txt $SFX/shared/hold"   deny  "enforce-high-disturbs"
echo 0.30 > "$SPROB"; sc_is "cp a.txt $SFX/shared/hold"   deny  "enforce-uncertain-band"
echo 0.05 > "$SPROB"; sc_is "cp a.txt $SFX/shared/hold"   allow "enforce-low-disturbs"
echo 0.30 > "$SPROB"; sc_out "cp a.txt $SFX/shared/hold" > "$SCT/deny.json"
T "scope:enforce-uncertain-reason-says-uncertain" jq -e '.hookSpecificOutput.permissionDecisionReason | contains("uncertain") and contains("final report")' "$SCT/deny.json"
T "scope:deny-output-is-valid-pretooluse" jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 40)' "$SCT/deny.json"
SC_URL="http://127.0.0.1:9" sc_is "cp a.txt $SFX/shared/hold"             allow "enforce-judge-down-allows-file-overwrite"
SC_URL="http://127.0.0.1:9" sc_is "ssh hyper01 'sudo systemctl restart x'" deny  "enforce-judge-down-denies-service-control"
SC_URL="http://127.0.0.1:9" sc_is "systemctl stop foo"                     deny  "enforce-judge-down-denies-systemctl"
SC_URL="http://127.0.0.1:9" sc_is "docker rm -f web"                       deny  "enforce-judge-down-denies-docker-rm"
SC_URL="http://127.0.0.1:9" sc_is "docker run -d --name t1 x && docker rm -f t1" allow "enforce-judge-down-own-container-ok"
SC_URL="http://127.0.0.1:9" sc_is "ssh hyper01 'cd /srv/app && git pull'"  allow "enforce-judge-down-allows-the-rest"
unset SC_ENF
# masking: nothing secret leaves the machine
rm -f "$SBODY"; echo 0.05 > "$SPROB"
GHT="ghp_$(printf 'Z%.0s' $(seq 36))"
sc_is "cp a.txt $SFX/shared/hold; echo token=$GHT" allow "masking-request-sent"
waitfor "$SBODY" && sleep 0.2
TN "scope:raw-secret-never-sent" grep -q "ZZZZZZZZZZ" "$SBODY"
T  "scope:mask-marker-sent" grep -q "REDACTED" "$SBODY"
# kill switch, and the guard calls it
OFFF="$SCT/off"; touch "$OFFF"
out=$(jq -n --arg c "kill $DECOY" --arg w "$SFX/work" '{tool_input:{command:$c}, cwd:$w}' | SCOPE_CHECK_OFF_FILE="$OFFF" SCOPE_CHECK_SESSION_PID=$$ "$SC")
if [ -z "$out" ]; then ok "scope:kill-switch-scope-check"; else bad "scope:kill-switch-scope-check" "got output"; fi
out=$(jq -n --arg c "kill $DECOY" --arg w "$SFX/work" '{tool_input:{command:$c}, cwd:$w}' | SCOPE_CHECK_OFF_FILE="$OFFF" SCOPE_CHECK_SESSION_PID=$$ SCOPE_CHECK_LOG="$SLOG" "$G")
if [ -z "$out" ]; then ok "scope:kill-switch-through-guard"; else bad "scope:kill-switch-through-guard" "got output"; fi
jq -n --arg c "kill $DECOY" --arg w "$SFX/work" '{tool_input:{command:$c}, cwd:$w}' | SCOPE_CHECK_OFF_FILE="$SCT/no-off" SCOPE_CHECK_SESSION_PID=$$ SCOPE_CHECK_LOG="$SLOG" "$G" > "$SCT/g1.json"
T "scope:guard-calls-scope-check" jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | startswith("scope-check:"))' "$SCT/g1.json"
jq -n --arg c "rm -rf /" --arg w "$SFX/work" '{tool_input:{command:$c}, cwd:$w}' | SCOPE_CHECK_OFF_FILE="$SCT/no-off" SCOPE_CHECK_SESSION_PID=$$ SCOPE_CHECK_LOG="$SLOG" "$G" > "$SCT/g2.json"
T "scope:guard-own-rules-still-first" jq -e '.hookSpecificOutput.permissionDecisionReason | startswith("pretool-guard:")' "$SCT/g2.json"
kill "$OWNPID" "$DECOY" "$SSRV" 2>/dev/null; wait "$OWNPID" "$SSRV" 2>/dev/null
rm -f "$SFX/shared/hold" "$SFX/shared/newfile" "$SFX/work/out.txt" "$SSP/srv.pid"
rmdir "$SFX/shared" "$SFX/work" "$SFX" 2>/dev/null
rm -rf "/private/tmp/claude-scopetest-$$" "$SCT"

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

# Password forms the token-shape rules used to miss. Every value below is a planted fake.
redacts env-zbpw     "ZB_PW=fake-value-123 ./run.sh"                                     "fake-value-123"
redacts env-pass     "export PASS=fakePass9x ./deploy"                                   "fakePass9x"
redacts env-passwd   "SVC_PASSWD=zzfake77 curl http://x"                                 "zzfake77"
redacts env-pwd-quot "DB_PWD='my fake pass 1' mysql -u root"                             "my fake pass"
redacts env-lower    "zb_pw=fake-lower-77 ./run.sh"                                      "fake-lower-77"
redacts sshpass      "sshpass -p fakeSshPw1 ssh -p 22 root@host uptime"                  "fakeSshPw1"
redacts sshpass-quot "sshpass -p 'fake ssh pw' ssh host"                                 "fake ssh pw"
redacts sshpass-opt  "sshpass -v -p fakeSshPw2 scp f host:/tmp"                          "fakeSshPw2"
redacts flag-space   "tool --password fakeFlag99 https://x"                              "fakeFlag99"
redacts flag-dbpw    "tool --db-password fakeFlag98 --other"                             "fakeFlag98"
redacts flag-secret  "tool --client-secret fakeFlag97 run"                               "fakeFlag97"
redacts mysql-attach "mysql -u root -pfakeMyPw1 db"                                      "fakeMyPw1"
redacts mysql-space  "mysql -u root -p fakeMyPw2 db"                                     "fakeMyPw2"
redacts mysql-quot   "mysql -u root -p'fake my pw' db"                                   "fake my pw"
redacts mysqldump    "mysqldump -h h -u u -pfakeDump1 db > out.sql"                      "fakeDump1"
redacts mysql-remote "ssh -p 22 host 'mysqladmin -u r -pfakeAdm1 status'"                "fakeAdm1"
redacts docker-login "docker login -u me -p fakeDock1 registry.example.com"              "fakeDock1"
redacts redis-cli    "redis-cli -h h -a fakeRedis1 ping"                                 "fakeRedis1"
redacts ldap-w       "ldapsearch -x -D cn=admin -w fakeLdap1 -b dc=x"                    "fakeLdap1"
redacts openssl-pass "openssl enc -aes-256-cbc -pass pass:fakeSsl1 -in f"                "fakeSsl1"
redacts curl-user    "curl -u admin:fakeCurl1 https://x"                                 "fakeCurl1"
redacts curl-user-q  "curl --user 'admin:fakeCurl2' https://x"                           "fakeCurl2"
redacts json-pw      "curl -d '{\"user\":\"a\",\"password\": \"fakeJson77\"}' https://x" "fakeJson77"
redacts json-esc     "curl -d '{\\\"password\\\":\\\"fakeJson78\\\"}' https://x"         "fakeJson78"
redacts prose-is     "echo the password is fakeProse1 > note.txt"                        "fakeProse1"
redacts prose-login  "echo log in as admin / fakeProse2 on the box"                      "fakeProse2"
redacts prose-userpw "echo user admin password fakeProse3"                               "fakeProse3"
redacts prose-pw     "echo login: admin pw: fakeProse4"                                  "fakeProse4"
redacts prose-creds  "echo credentials: admin:fakeProse5"                                "fakeProse5"
redacts prose-setto  "echo password changed to fakeProse6x"                              "fakeProse6x"
# The NAME is the signal: a password-like name masks the value whatever its shape. Planted fakes, all lowercase words
# joined by - or _ (the shape the prose heuristic used to let through), plus quoted values with spaces.
redacts name-hyphen  "ZB_PW=fake-value-xyz ./run.sh"                                     "fake-value-xyz"
redacts name-under   "ZB_PW=fake_value_xyz ./run.sh"                                     "fake_value_xyz"
redacts name-short   "ZB_PW=abc-def ./run.sh"                                            "abc-def"
redacts name-phrase  "ZB_PW=correct-horse-battery ./run.sh"                              "correct-horse-battery"
redacts name-word    "ZB_PW=fakevaluexyz ./run.sh"                                       "fakevaluexyz"
redacts name-spaces  "ZB_PW='fake value xyz' ./run.sh"                                   "fake value xyz"
redacts name-dq      "ZB_PW=\"fake-value xyz\" ./run.sh"                                  "fake-value xyz"
redacts name-pwd     "DB_PWD=fake-value-xyz ./run.sh"                                    "fake-value-xyz"
redacts name-pass    "export SVC_PASS=correct-horse-battery"                             "correct-horse-battery"
redacts name-passwd  "MYSQL_PASSWD=correct-horse-battery run"                            "correct-horse-battery"
redacts name-concat  "DBPASS=fake-value-xyz run"                                         "fake-value-xyz"
redacts name-lower   "zb_pw=fake-value-xyz run"                                          "fake-value-xyz"
redacts name-bare    "pass=fake-value-xyz run"                                           "fake-value-xyz"
redacts name-true    "ZB_PW=true run"                                                    "ZB_PW=true"
redacts name-secret  "CLIENT_SECRET=fake-value-xyz run"                                  "fake-value-xyz"
redacts name-token   "API_TOKEN=correct-horse-battery run"                              "correct-horse-battery"
redacts name-apikey  "MY_API_KEY=fake-value-xyz run"                                     "fake-value-xyz"
redacts flag-hyphen  "tool --password fake-value-xyz run"                                "fake-value-xyz"
redacts flag-under   "tool --pass fake_value_xyz run"                                    "fake_value_xyz"
redacts flag-phrase  "tool --db-password correct-horse-battery run"                      "correct-horse-battery"
redacts flag-yes     "tool --password yes run"                                           "--password yes"
redacts mysql-phrase "mysql -u r -p correct-horse-battery db"                            "correct-horse-battery"
redacts sshpass-ph   "sshpass -p correct-horse-battery ssh h"                            "correct-horse-battery"
# The forms the masking worker's notes still listed as missed. Every value is a planted fake.
redacts smb-user     "smbclient //srv/share -U alice%fakePw9x -c ls"                     "fakePw9x"
redacts smb-user-eq  "smbclient //srv/share --user=alice%fakePw9x"                       "fakePw9x"
redacts smb-messy    "smbclient //srv/share -U 'alice%ab1&cd2;ef3)gh4'"                  "ab1&cd2;ef3)gh4"
redacts htpasswd-b   "htpasswd -b /etc/apache2/.htpasswd alice fakePw9x"                 "fakePw9x"
redacts htpasswd-bc  "htpasswd -bc /etc/x alice fakePw9x"                                "fakePw9x"
redacts htpasswd-nb  "htpasswd -nb alice fakePw9x"                                       "fakePw9x"
redacts htpasswd-c10 "htpasswd -b -B -C 10 file alice fakePw9x"                          "fakePw9x"
redacts chpasswd-echo "echo alice:fakePw9x | chpasswd"                                   "fakePw9x"
redacts chpasswd-sudo 'echo "alice:fakePw9x" | sudo chpasswd'                            "fakePw9x"
redacts chpasswd-many "printf 'alice:fakePw9x\nbob:9otherPw\n' | sudo chpasswd"          "9otherPw"
redacts chpasswd-here "chpasswd <<< 'alice:fakePw9x'"                                    "fakePw9x"
redacts sudo-echo    "echo fakePw9x | sudo -S apt update"                                "fakePw9x"
redacts sudo-quoted  "echo 'fakePw9x' | sudo -S -v"                                      "fakePw9x"
redacts sudo-printf  "printf '%s\n' fakePw9x | sudo -S systemctl restart x"              "fakePw9x"
redacts sudo-format  "printf 'fakePw9x\n' | sudo -S -v"                                  "fakePw9x"
redacts sudo-flag    "echo -n fakePw9x | sudo -k -S true"                                "fakePw9x"
redacts pw-colon     "login: alice pw: hunter"                                           "hunter"
redacts pw-colon-up  "PW: swordfish"                                                     "swordfish"
redacts env-amp      "ZB_PW=ab1&cd2;ef3)gh4 ./run.sh"                                    "ab1&cd2;ef3)gh4"
redacts env-paren    "PASS=ab1)cd2 true"                                                 "ab1)cd2"
redacts env-escaped  "PASSWORD=fake\ pass\ 9x ./run.sh"                                  "fake\ pass\ 9x"
redacts flag-amp     "--password ab1&cd2;ef3)gh4 host"                                   "ab1&cd2;ef3)gh4"
redacts sshpass-amp  "sshpass -p ab1&cd2;ef3)gh4 ssh host"                               "ab1&cd2;ef3)gh4"
expect_out() { # label, input, exact expected output: only the value changes, the command shape stays
  local out; out=$(printf '%s' "$2" | "$J" redact)
  if [ "$out" = "$3" ]; then ok "jev-redact:shape:$1"; else bad "jev-redact:shape:$1" "got '$out'"; fi
}
expect_out env       "ZB_PW=fake-value-123 ./run.sh"                          "ZB_PW=[REDACTED:pw] ./run.sh"
expect_out sshpass   "sshpass -p fakeSshPw1 ssh -p 22 root@host uptime"       "sshpass -p [REDACTED:pw] ssh -p 22 root@host uptime"
expect_out mysql     "mysql -u root -pfakeMyPw1 db"                           "mysql -u root -p[REDACTED:pw] db"
expect_out flag      "tool --password fakeFlag99 https://x"                   "tool --password [REDACTED:pw] https://x"
expect_out curl-user "curl -u admin:fakeCurl1 https://x"                      "curl -u admin:[REDACTED:pw] https://x"
expect_out json      "{\"password\": \"fakeJson77\"}"                         "{\"password\": \"[REDACTED:value]\"}"
expect_out prose     "log in as admin / fakeProse2 on the box"                "log in as admin / [REDACTED:prose-password] on the box"
expect_out smb-user  "smbclient //srv/share -U alice%fakePw9x -c ls"          "smbclient //srv/share -U alice%[REDACTED:pw] -c ls"
expect_out htpasswd  "htpasswd -b file alice fakePw9x"                        "htpasswd -b file alice [REDACTED:pw]"
expect_out chpasswd  "echo alice:fakePw9x | chpasswd"                         "echo alice:[REDACTED:pw] | chpasswd"
expect_out sudo-S    "echo fakePw9x | sudo -S apt update"                     "echo [REDACTED:pw] | sudo -S apt update"
expect_out pw-colon  "login: alice pw: hunter"                                "login: alice pw: [REDACTED:prose-password]"
expect_out env-amp   "ZB_PW=ab1&cd2;ef3)gh4 ./run.sh"                         "ZB_PW=[REDACTED:pw] ./run.sh"
expect_out env-end   "(ZB_PW=ab1cd2; ./run.sh)"                               "(ZB_PW=[REDACTED:pw]; ./run.sh)"
expect_out flag-amp  "--password ab1&cd2;ef3)gh4 host"                        "--password [REDACTED:pw] host"
# A huge hyphenated or repeated command must not pin a CPU in the background: each stays under 5 seconds.
slow_in() { # label, unit, repeat count
  local t0 t1; t0=$(python3 -c 'import time;print(time.time())')
  python3 -c "import sys; sys.stdout.write(sys.argv[1]*int(sys.argv[2]))" "$2" "$3" | "$J" redact >/dev/null 2>&1
  t1=$(python3 -c 'import time;print(time.time())')
  if python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 5 else 1)"; then ok "jev-redact:fast:$1"; else bad "jev-redact:fast:$1" "took over 5s"; fi
}
slow_in hyphens "ab-" 70000
slow_in mysql-words "mysql " 30000
slow_in docker-login "docker login " 20000
slow_in pw-hyphens "pw-" 100000
# Ordinary commands that look close to the forms above stay exactly as they are.
untouched 'git status'                                   "git-status"
untouched 'ssh -p 22 host'                               "ssh-port"
untouched 'scp -P 2222 f.txt host:/tmp'                  "scp-port"
untouched 'grep -p foo file.txt'                         "grep-p"
untouched 'sshpass -e ssh -p 22 host uptime'             "sshpass-env-ssh-port"
untouched 'sshpass -f /root/pwfile ssh host'             "sshpass-file"
untouched 'mysql -u root -p'                             "mysql-prompt"
untouched 'mysql -u root -p -e "select 1"'               "mysql-prompt-then-flag"
untouched 'mysql -h db -P 3306 -u root'                  "mysql-port"
untouched 'mysql -u root < dump.sql'                     "mysql-redirect"
untouched 'find . -name "*.log" -print'                  "find-print"
untouched 'mysqldump db | gzip | find /b -print'         "mysql-then-find"
untouched 'echo the password prompt appears first'       "prose-password-prompt"
untouched 'git commit -m "fix: password is stored hashed"' "prose-password-stop-word"
untouched 'echo "Enter password: "'                      "prompt-text"
untouched 'cd "$PWD" && ls'                              "pwd-variable"
untouched 'PWD=/home/me/dev ls'                          "pwd-path"
untouched 'export PASSWORD=$(cat /run/secrets/pw)'       "password-from-file"
untouched 'tool --password "$DB_PASSWORD" run'           "flag-variable"
untouched 'tool --password-stdin registry.example.com'   "password-stdin"
untouched 'tool --token-file /run/tok run'               "token-file"
untouched 'curl -u admin https://x'                      "curl-user-no-password"
untouched 'curl -d "{\"max_tokens\": 100}" https://x'    "max-tokens-json"
untouched 'docker run -p 8080:80 nginx'                  "docker-run-port"
untouched 'docker login registry.example.com'            "docker-login-prompt"
untouched 'compass=north ./go'                           "compass-variable"
untouched 'ZB_PW=$ZB_PW ./run.sh'                        "name-var"
untouched 'ZB_PW=${ZB_PW} ./run.sh'                      "name-var-braces"
untouched 'ZB_PW="$ZB_PW" ./run.sh'                      "name-var-quoted"
untouched 'DB_PASS=$(cat /run/secrets/pw) run'           "name-command-sub"
untouched 'tool --password ${DB_PW} run'                 "flag-var-braces"
untouched 'PWD=abc-def ls'                               "bare-pwd-is-cwd"
untouched 'bypass=north-east ./go'                       "bypass-word"
# Close-but-not-password forms for the six new rules stay exactly as they are.
untouched 'smbclient //srv/share -U alice'               "smb-no-password"
untouched 'smbclient //srv/share --user=alice'           "smb-no-password-eq"
untouched 'htpasswd -n alice'                            "htpasswd-prompt"
untouched 'htpasswd file alice'                          "htpasswd-no-b"
untouched 'htpasswd -b'                                  "htpasswd-no-args"
untouched 'echo hello | chpasswd'                        "chpasswd-nonpasswd"
untouched 'sudo -s'                                      "sudo-lower-s"
untouched 'echo $PW | sudo -S true'                      "sudo-var"
untouched 'pwd: /tmp'                                    "pwd-colon"
untouched 'pw: none'                                     "pw-none"
untouched 'pw: prompt'                                   "pw-prompt"
untouched 'pw: $PW'                                      "pw-var"

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

# ---- stop-check (Stop / SubagentStop: "stop or continue?" decided by Jev) -----
# A stub service answers with a probability read from a file, so every path of the
# hook runs for real: block, allow, service down / slow / erroring, loop cap, kill
# switch, background tasks, masking, and the transcript fallback.
SC="$HERE/hooks/stop-check.sh"
ST=$(mktemp -d); SPORT="$ST/port"; SBODY="$ST/body"; SP="$ST/p"; SMODE="$ST/mode"
echo 0.95 > "$SP"; echo ok > "$SMODE"; : > "$SBODY"
python3 - "$SPORT" "$SBODY" "$SP" "$SMODE" <<'PYEOF' &
import http.server, json, sys, time
portfile, bodyfile, pfile, modefile = sys.argv[1:5]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        data = self.rfile.read(n)
        with open(bodyfile, "ab") as f: f.write(data + b"\n")
        mode = open(modefile).read().strip()
        p = float(open(pfile).read().strip())
        if mode == "slow": time.sleep(10)
        if mode == "err500":
            self.send_response(500); self.send_header("content-length", "0"); self.end_headers(); return
        body = b"not json at all" if mode == "garbage" else json.dumps({"answers": {"stop": {"type": "choice", "choice": "x",
            "probabilities": {"done": (1 - p) / 4, "answered": (1 - p) / 4, "waiting_on_background": (1 - p) / 4, "owner_only": (1 - p) / 4, "handing_back": p}}}}).encode()
        try:
            self.send_response(200); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
        except OSError: pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PYEOF
SSTUB=$!
for _ in $(seq 50); do [ -s "$SPORT" ] && break; sleep 0.1; done
SURL="http://127.0.0.1:$(cat "$SPORT")"
export STOP_CHECK_URL="$SURL" STOP_CHECK_OFF_FILE="$ST/off" STOP_CHECK_STATE_DIR="$ST/state" STOP_CHECK_LOG="$ST/log" STOP_CHECK_TIMEOUT=4
unset STOP_CHECK_THRESHOLD STOP_CHECK_MAX_BLOCKS STOP_CHECK_QUESTION_FILE
# stop_event TEXT [SESSION] [extra jq object]: the JSON Claude Code sends on stdin
stop_event() { jq -nc --arg t "$1" --arg s "${2:-s1}" --argjson x "${3:-{\}}" '{hook_event_name:"Stop", session_id:$s, stop_hook_active:false, background_tasks:[], last_assistant_message:$t} + $x'; }
sc() { stop_event "$@" | "$SC"; }              # prints the hook's stdout
dec() { local o; o=$(cat); if [ -z "$o" ]; then echo allow; else printf '%s' "$o" | jq -r '.decision // "bad"' 2>/dev/null || echo bad; fi; }   # hook stdout -> block|allow
sc_decision() { sc "$@" | dec; }
setp() { echo "$1" > "$SP"; }; setmode() { echo "$1" > "$SMODE"; }
HAND="I changed the config. Want me to run the tests now? Say go and I will."

# 1. block: valid JSON with decision and reason, the reason says what to do
setp 0.95; : > "$SBODY"
out=$(sc "$HAND" blk)
T  "stop-check:block-is-valid-json" bash -c "printf '%s' '$(printf '%s' "$out" | sed "s/'/'\\\\''/g")' | jq -e '(keys|sort) == [\"decision\",\"reason\"] and .decision == \"block\" and (.reason|type) == \"string\"'"
T  "stop-check:block-reason-says-what-to-do" bash -c "printf '%s' \"\$1\" | jq -e '.reason | contains(\"handback\") and contains(\"95%\") and contains(\"owner-only\") and contains(\"continue\")'" _ "$out"
# 2. allow: nothing on stdout, exit 0
setp 0.05
o=$(stop_event "All done: 43 tests pass, pushed to origin." low | "$SC"); rc=$?
if [ -z "$o" ] && [ "$rc" -eq 0 ]; then ok "stop-check:allow-is-silent"; else bad "stop-check:allow-is-silent" "rc=$rc out=$o"; fi
# threshold is inclusive
setp 0.50; d=$(STOP_CHECK_THRESHOLD=0.50 sc_decision "$HAND" thr1); [ "$d" = block ] && ok "stop-check:threshold-inclusive" || bad "stop-check:threshold-inclusive" "got $d"
setp 0.49; d=$(STOP_CHECK_THRESHOLD=0.50 sc_decision "$HAND" thr2); [ "$d" = allow ] && ok "stop-check:below-threshold-allows" || bad "stop-check:below-threshold-allows" "got $d"
setp 0.95

# 3. the request: right model, the five classes, masked text only
: > "$SBODY"; SECRET1="ghp_$(printf 'Q%.0s' $(seq 36))"; SECRET2="fake-value-xyz"
sc "Deploy key is $SECRET1 and ZB_PW=$SECRET2 ./run.sh. Want me to continue?" mask >/dev/null
T  "stop-check:request-model-and-classes" bash -c "head -1 '$SBODY' | jq -e '.model == \"jev-stop-check\" and (.questions.stop.type == \"choice\") and ((.questions.stop.criteria|keys|sort) == [\"answered\",\"done\",\"handing_back\",\"owner_only\",\"waiting_on_background\"])'"
TN "stop-check:raw-token-never-sent"    grep -q "QQQQQQQQQQ" "$SBODY"
TN "stop-check:raw-password-never-sent" grep -q "$SECRET2" "$SBODY"
T  "stop-check:mask-marker-sent"        grep -q "REDACTED" "$SBODY"
T  "stop-check:sends-agent-message"     grep -q "Want me to continue" "$SBODY"

# 4. fail open: service down, black-holed, slow, error, garbage -> allow, inside the time limit
timed_allow() { # label, url, mode
  local t0 t1 d el
  t0=$(python3 -c 'import time;print(time.time())')
  d=$(STOP_CHECK_URL="$2" STOP_CHECK_TIMEOUT=2 sc_decision "$HAND" "fo-$1")
  t1=$(python3 -c 'import time;print(time.time())')
  el=$(python3 -c "print(round($t1 - $t0, 2))")
  if [ "$d" = allow ] && python3 -c "import sys; sys.exit(0 if $el < 4.0 else 1)"; then ok "stop-check:fail-open:$1 (${el}s)"; else bad "stop-check:fail-open:$1" "decision=$d after ${el}s"; fi
}
timed_allow refused    "http://127.0.0.1:1"
timed_allow blackhole  "http://192.0.2.1:9"
setmode slow;    timed_allow slow    "$SURL"
setmode err500;  timed_allow http500 "$SURL"
setmode garbage; timed_allow garbage "$SURL"
setmode ok

# 5. loop cap: two blocks in a row, then the third stop is allowed, then it starts over
d1=$(sc_decision "$HAND" cap); d2=$(sc_decision "$HAND" cap); d3=$(sc_decision "$HAND" cap); d4=$(sc_decision "$HAND" cap); d5=$(sc_decision "$HAND" cap); d6=$(sc_decision "$HAND" cap)
[ "$d1 $d2 $d3 $d4 $d5 $d6" = "block block allow block block allow" ] && ok "stop-check:loop-cap-2" || bad "stop-check:loop-cap-2" "got $d1 $d2 $d3 $d4 $d5 $d6"
# an allowed stop in between resets the counter
setp 0.95; a=$(sc_decision "$HAND" rst); setp 0.05; b=$(sc_decision "done" rst); setp 0.95; c=$(sc_decision "$HAND" rst); e=$(sc_decision "$HAND" rst); f=$(sc_decision "$HAND" rst)
[ "$a $b $c $e $f" = "block allow block block allow" ] && ok "stop-check:allowed-stop-resets-counter" || bad "stop-check:allowed-stop-resets-counter" "got $a $b $c $e $f"
# sessions and subagents count separately
a=$(sc_decision "$HAND" sessA); b=$(sc_decision "$HAND" sessA); c=$(sc_decision "$HAND" sessB)
d=$(stop_event "$HAND" sessA '{"hook_event_name":"SubagentStop","agent_id":"ag1"}' | "$SC" | dec)
[ "$a $b $c $d" = "block block block block" ] && ok "stop-check:counter-per-session-and-agent" || bad "stop-check:counter-per-session-and-agent" "got $a $b $c $d"
# the cap is configurable
setp 0.95; a=$(STOP_CHECK_MAX_BLOCKS=1 sc_decision "$HAND" max1); b=$(STOP_CHECK_MAX_BLOCKS=1 sc_decision "$HAND" max1)
[ "$a $b" = "block allow" ] && ok "stop-check:max-blocks-setting" || bad "stop-check:max-blocks-setting" "got $a $b"

# 6. kill switch: the file makes it allow without asking the service
: > "$SBODY"; touch "$ST/off"
d=$(sc_decision "$HAND" kill)
rm -f "$ST/off"
if [ "$d" = allow ] && [ ! -s "$SBODY" ]; then ok "stop-check:kill-switch"; else bad "stop-check:kill-switch" "decision=$d, request sent: $([ -s "$SBODY" ] && echo yes || echo no)"; fi
d=$(sc_decision "$HAND" kill2); [ "$d" = block ] && ok "stop-check:kill-switch-removed-resumes" || bad "stop-check:kill-switch-removed-resumes" "got $d"

# 7. background tasks still running: allowed, no question asked
: > "$SBODY"
d=$(stop_event "$HAND" bg '{"background_tasks":[{"id":"b1","type":"shell","status":"running","command":"sleep 20"}]}' | "$SC" | dec)
if [ "$d" = allow ] && [ ! -s "$SBODY" ]; then ok "stop-check:background-tasks-allow"; else bad "stop-check:background-tasks-allow" "decision=$d"; fi

# 8. no text, bad input: allow
d=$(sc_decision "" empty); [ "$d" = allow ] && ok "stop-check:empty-message-allows" || bad "stop-check:empty-message-allows" "got $d"
o=$(printf 'this is not json' | "$SC"); [ -z "$o" ] && ok "stop-check:bad-input-allows" || bad "stop-check:bad-input-allows" "got $o"

# 9. Stop with no last_assistant_message: read the transcript (last assistant text, last owner message)
TR="$ST/transcript.jsonl"
{ printf '%s\n' '{"type":"user","message":{"role":"user","content":"please set up the build"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Set up. Shall I also add CI?"}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"TRANSCRIPT-FALLBACK-TEXT shall I go ahead?"}]}}'; } > "$TR"
: > "$SBODY"
d=$(jq -nc --arg p "$TR" '{hook_event_name:"Stop", session_id:"tr1", transcript_path:$p, stop_hook_active:false}' | "$SC" | dec)
if [ "$d" = block ] && grep -q "TRANSCRIPT-FALLBACK-TEXT" "$SBODY" && grep -q "please set up the build" "$SBODY"; then ok "stop-check:transcript-fallback"; else bad "stop-check:transcript-fallback" "decision=$d"; fi

# 10. the question the hook sends is the one the eval chose
T "stop-check:question-matches-selected" bash -c "[ \"\$(\"$SC\" question | jq -S -c .)\" = \"\$(jq -S -c '. + {type:\"choice\"}' '$HERE/eval/stop-check/questions/selected.json')\" ]"
# 11. the settings mirror wires both events to the installed hook
T "stop-check:settings-wires-Stop"         bash -c "jq -e '.hooks.Stop[0].hooks[0].command == \"\$HOME/.claude/hooks/stop-check.sh\"' '$HERE/settings.json'"
T "stop-check:settings-wires-SubagentStop" bash -c "jq -e '.hooks.SubagentStop[0].hooks[0].command == \"\$HOME/.claude/hooks/stop-check.sh\"' '$HERE/settings.json'"

kill "$SSTUB" 2>/dev/null; wait "$SSTUB" 2>/dev/null
unset STOP_CHECK_URL STOP_CHECK_OFF_FILE STOP_CHECK_STATE_DIR STOP_CHECK_LOG STOP_CHECK_TIMEOUT
rm -rf "$ST"

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
T "sessctx:warns-names-stop-check" has "$LONE" "hook stop-check.sh missing"
TN "sessctx:no-retired-stop-gate-warning" has "$LONE" "stop-gate.sh"
rm -rf "$SCD"
# the real hooks dir is complete, so a session start prints no ABSENT warning
FULL=$(sc "$R8")
TN "sessctx:no-warning-when-hooks-present" has "$FULL" "silently ABSENT"
T  "sessctx:full-dir-still-prints-context" has "$FULL" "GATE ABSENT"

# ---- install.sh dry-run is inert --------------------------------------------
T "install:dry-run-clean" bash -c "'$HERE/install.sh' --dry-run | grep -q 'would:'"
T "install:dry-run-no-writes" bash -c "
  BEFORE=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  '$HERE/install.sh' --dry-run >/dev/null
  AFTER=\$(ls -la \"\$HOME/.claude\" 2>/dev/null | shasum)
  [ \"\$BEFORE\" = \"\$AFTER\" ]"

rm -rf "$W" "$R" "$R2" "${R3:-}" "$R4" "$R5" "$R6" "$R7" "$R8" 2>/dev/null
rm -f "$TMP/claude-base-edited-basetest-"* 2>/dev/null


# ---- project-level harness takes precedence ---------------------------------
# Hooks from ~/.claude and <repo>/.claude both run. A repo that carries its own
# harness must not get two gates.
PW=$(mktemp -d); mkdir -p "$PW/.claude"
printf '#!/usr/bin/env bash\necho OWNFAIL\nexit 1\n' > "$PW/.claude/verify.sh"; chmod +x "$PW/.claude/verify.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]}}' > "$PW/.claude/settings.json"
SCOUT=$(printf '{"cwd":"%s"}' "$PW" | "$SC" 2>/dev/null)
if [ -z "$SCOUT" ]; then ok "defer:sessctx-yields-to-project"; else bad "defer:sessctx-yields-to-project"; fi
rm -rf "$PW"

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
