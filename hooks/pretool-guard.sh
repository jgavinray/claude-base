#!/usr/bin/env bash
# PreToolUse (Bash): two-tier gate on destructive commands.
#
#   DENY — unrecoverable or blast-radius-unbounded. Blocked outright.
#   ASK  — genuinely useful but destructive. Prompts instead of blocking, so
#          routine work is not wedged but never happens silently.
#
# This matters more than it looks: with skipDangerousModePermissionPrompt set,
# this hook is the ONLY thing standing between an agent and your cluster. The
# command list is therefore weighted toward Kubernetes/Terraform/cloud CLIs, not
# just `rm -rf /`.
#
# It is a denylist over text, so it is a FLOOR, not a fence: obfuscation, shell
# variables, and scripts-that-call-scripts all defeat it by construction. Treat
# it as protection against accidents, never against a determined process.
set -u

CMD=$(jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Normalize: collapse whitespace and strip quotes, so `rm  -r  -f  /` and
# `rm -rf "/"` match the same pattern as `rm -rf /`.
N=$(printf '%s' "$CMD" | tr '\n' ' ' | tr -s '[:space:]' ' ' | tr -d "'\"")

# Disable globbing before any word-splitting loop below. Without this, iterating
# an unquoted `rm -rf *` expands the `*` against the hook's own cwd and the
# literal argument we need to catch disappears.
set -f

decide() { # decision, reason
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

m() { printf '%s' "$N" | grep -qiE "$1"; }

# ------------------------------------------------------- recursive delete (rm)
# Handled by ALLOWLIST, not denylist. A denylist cannot work here: `rm -rf /` is
# the case that never actually happens, while `rm -rf ./src` — indistinguishable
# from legitimate cleanup by pattern alone — is the one that eats a project.
#
# So: enumerate the paths that are safe to blow away (build output, caches,
# vendored deps), allow those silently, and ASK about every other recursive
# delete. Unrecoverable targets stay a hard DENY.
EPHEMERAL='^(\./)?(node_modules|build|dist|out|target|coverage|htmlcov|\.next|\.nuxt|\.svelte-kit|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.venv|venv|env|\.cache|tmp|temp|[^/]*\.egg-info)(/.*)?/?$'

# Scan tokens once: find `rm`, note whether a recursive flag is set, collect
# targets. Checking flags as tokens (not by grepping the whole line for "r")
# avoids classifying `rm -f server.log` as recursive.
RECURSIVE=0
TARGETS=""
SEEN=0
for w in $N; do
  if [ "$w" = "rm" ] || [ "$w" = "/bin/rm" ]; then SEEN=1; RECURSIVE=0; TARGETS=""; continue; fi
  [ "$SEEN" -eq 1 ] || continue
  case "$w" in
    '&&'|'||'|';'|'|') SEEN=0; continue ;;   # end of this command
    # `-*[rR]*` and not `-[a-zA-Z]*[rR]*`: in `-rf` the r IS the first flag
    # character, so requiring a letter before it matches nothing.
    -*[rR]*)           RECURSIVE=1 ;;
    -*)                ;;                    # some other flag
    *)                 TARGETS="$TARGETS $w" ;;
  esac
done

if [ "$RECURSIVE" -eq 1 ]; then
  for w in $TARGETS; do

    # Unrecoverable: filesystem root, home itself, or the whole current tree.
    case "$w" in
      /|'~'|'~/'|'$HOME'|'$HOME/'|.|./|..|../|'*'|'./*')
        decide deny "pretool-guard: 'rm -r $w' would remove everything under it and has no targeted alternative. Blocked — name the specific path you mean." ;;
    esac

    # Known-ephemeral build/cache output: allow without interrupting.
    printf '%s' "$w" | grep -qE "$EPHEMERAL" && continue

    # Absolute path outside /tmp: never a build artifact.
    case "$w" in
      /tmp/*|/private/tmp/*|/var/folders/*) continue ;;
      /*) decide deny "pretool-guard: 'rm -r $w' targets an absolute path outside /tmp. Blocked — this is how a project directory disappears." ;;
      '~'/*|'$HOME'/*) decide deny "pretool-guard: 'rm -r $w' targets a path under your home directory. Blocked — use a path relative to the project." ;;
    esac

    # Anything else recursive: recoverable only if it is committed. Ask.
    decide ask "pretool-guard: recursive delete of '$w', which is not a recognized build/cache directory. Uncommitted or untracked files there are unrecoverable. Confirm?"
  done
fi

# find -delete / -exec rm: same blast radius, different spelling.
m 'find +.*-delete'          && decide ask "pretool-guard: 'find -delete' removes every match. Confirm?"
m 'find +.*-exec +rm'        && decide ask "pretool-guard: 'find -exec rm' removes every match. Confirm?"

# ------------------------------------------------------------------ DENY tier
# Filesystem / host
m 'mkfs\.'                                    && decide deny "pretool-guard: filesystem format — blocked."
m 'dd +.*of=/dev/'                            && decide deny "pretool-guard: raw write to block device — blocked."
m '> */dev/(sd|nvme|disk|hd)'                 && decide deny "pretool-guard: redirect over block device — blocked."
m 'chmod +-R +777 +/'                         && decide deny "pretool-guard: recursive 777 on / — blocked."
m ':\(\) *\{ *: *\| *: *& *\} *;:'            && decide deny "pretool-guard: fork bomb — blocked."
m '\b(shutdown|reboot)\b'                     && decide deny "pretool-guard: host power control — blocked."

# Kubernetes: namespace and storage deletion are not recoverable from git
m 'kubectl +.*delete +.*(namespace|^ns | ns )' && decide deny "pretool-guard: namespace deletion — blocked. Delete specific resources instead."
m 'kubectl +.*delete +.*--all'                 && decide deny "pretool-guard: --all deletion — blocked. Name the resource explicitly."
m 'kubectl +.*delete +.*(persistentvolume|\bpvc\b|\bpv\b)' && decide deny "pretool-guard: PV/PVC deletion destroys data — blocked."
m 'helm +(uninstall|delete) '                  && decide deny "pretool-guard: helm uninstall — blocked. Use a targeted rollback."
m 'argocd +app +delete'                        && decide deny "pretool-guard: argocd app delete — blocked."
m 'flux +uninstall'                            && decide deny "pretool-guard: flux uninstall — blocked."

# Infrastructure as code
m 'terraform +destroy'                         && decide deny "pretool-guard: terraform destroy — blocked."

# Cloud CLIs
m 'aws +s3 +(rb|rm +.*--recursive)'            && decide deny "pretool-guard: recursive S3 delete — blocked."
m 'aws +.*delete-(cluster|bucket|stack|db-instance|table)' && decide deny "pretool-guard: AWS resource deletion — blocked."
m 'az +group +delete'                          && decide deny "pretool-guard: Azure resource-group delete — blocked."
m 'gcloud +.*(projects|clusters|instances) +delete' && decide deny "pretool-guard: GCP resource deletion — blocked."

# Data
m '\b(drop +database|drop +schema|truncate +table)\b' && decide deny "pretool-guard: destructive SQL — blocked."

# Git: force-push, unless it is the safe variant
if m 'git +push +.*(--force|[^a-z-]-f\b)'; then
  m 'git +push +.*--force-with-lease' || decide deny "pretool-guard: force push — blocked. Use --force-with-lease."
fi

# ------------------------------------------------------------------- ASK tier
m 'kubectl +.*delete '        && decide ask "pretool-guard: this deletes a live Kubernetes resource. Confirm?"
m 'terraform +apply'          && decide ask "pretool-guard: terraform apply mutates real infrastructure. Confirm?"
m 'git +reset +--hard'        && decide ask "pretool-guard: this discards uncommitted work. Confirm?"
m 'git +clean +-[a-z]*f'      && decide ask "pretool-guard: this deletes untracked files. Confirm?"
m 'git +checkout +\. *$'      && decide ask "pretool-guard: this discards all unstaged changes. Confirm?"
m 'git +branch +-D '          && decide ask "pretool-guard: force-delete branch (may drop unmerged commits). Confirm?"
m 'docker +(system +)?prune'  && decide ask "pretool-guard: this removes Docker state. Confirm?"
m '(npm +publish|cargo +publish|twine +upload|gh +release +create)' && decide ask "pretool-guard: this publishes externally and cannot be unpublished cleanly. Confirm?"

exit 0
