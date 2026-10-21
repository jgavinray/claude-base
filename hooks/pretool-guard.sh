#!/usr/bin/env bash
# PreToolUse (Bash): gate on destructive commands.
#
#   DENY  — unrecoverable, or impossible to check. Blocked with a reason the
#           agent can act on (write the literal path, commit first, use the
#           Trash), so the owner is not pulled in.
#   ASK   — only actions that are the owner's call by nature: publishing,
#           deleting live Kubernetes resources, terraform apply.
#   ALLOW — everything recoverable: build/cache output, temp dirs, and files
#           git can bring back.
#
# 10/20/2026: recursive deletes, find -delete and git discards no longer ASK.
# The owner was prompted about 25 times in one day, mostly for false positives
# (multi-line commands read as one, `client/node_modules`, scratch dirs). Each
# case is now decided from the filesystem and git instead of a prompt.
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

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CWD" ] || CWD=$PWD

# Heredoc bodies are data (commit messages, files being written, scripts for
# python), not commands, so they are dropped before matching. The exception is
# a heredoc fed to a shell or ssh, which runs as commands and stays.
CMD=$(printf '%s' "$CMD" | perl -ne '
  if (defined $tag) {
    if (/^\s*\Q$tag\E\s*$/) { undef $tag; print; next }
    print if $keep; next;
  }
  if (/(?<!<)<<(?!<)-?\s*["\x27]?([A-Za-z_][A-Za-z0-9_]*)["\x27]?/) {
    $tag = $1;
    $keep = (substr($_, 0, $-[0]) =~ /(^|[\s;&|(])(bash|sh|zsh|dash|ssh)(\s|$)/) ? 1 : 0;
  }
  print')

# Normalize: join backslash-continued lines, let every other newline end a
# command the way `;` does, collapse whitespace and strip quotes, so
# `rm  -r  -f  /` and `rm -rf "/"` match the same pattern as `rm -rf /`.
N=$(printf '%s' "$CMD" | perl -0777 -pe 's/\\\n/ /g; s/\n/ ; /g' | tr -s '[:space:]' ' ' | tr -d "'\"")

# Command position: start of a command, or after sudo, ssh HOST, bash -c and
# the like. Used where a word could also appear in a message or an argument
# (`git commit -m "drop git reset --hard"` is not a reset).
CP='(^|[;&|(] *|(sudo|then|do|xargs|-c) +|ssh +[^ ]+ +)'

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

# Build output, caches and vendored deps: safe to blow away.
EPH='node_modules|build|dist|out|target|coverage|htmlcov|\.next|\.nuxt|\.svelte-kit|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.venv|venv|env|\.cache|tmp|temp|[^/]*\.egg-info'

# Resolve `$NAME` / `${NAME}` in a word from assignments made earlier in the
# same command (e.g. `SP=/private/tmp/…; T=$SP/x; rm -rf $T`), following
# chained assignments a few levels deep. `$HOME` is left literal so the home
# rules below still apply. Anything unresolvable keeps its `$`.
resolve_word() {
  local w="$1" depth=0 ref bare val
  while [ "$depth" -lt 6 ]; do
    case "$w" in *'$'*) ;; *) break ;; esac
    ref=$(printf '%s' "$w" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | head -1)
    [ -z "$ref" ] && break
    bare=${ref#\$}; bare=${bare#\{}; bare=${bare%\}}
    [ "$bare" = "HOME" ] && break
    val=$(printf '%s' "$N" | grep -oE "(^|[ ;&|(])$bare=[^ ;&|)]+" | tail -1 | sed -E "s/^[ ;&|(]?$bare=//")
    [ -z "$val" ] && break
    w=${w/"$ref"/$val}
    depth=$((depth + 1))
  done
  printf '%s' "$w"
}

normpath() { # absolute path → same path with `.`, `..` and `//` folded away
  local IFS=/ seg out=""
  for seg in $1; do
    case "$seg" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

to_abs() { # base dir, path → absolute normalized path; "?" if the base is unknown
  local base="$1" p="$2"
  case "$p" in
    /*) ;;
    '~'|'$HOME') p=$HOME ;;
    '~'/*) p="$HOME/${p#\~/}" ;;
    '$HOME'/*) p="$HOME/${p#\$HOME/}" ;;
    *) if [ "$base" = "?" ]; then printf '?'; return; fi; p="$base/$p" ;;
  esac
  normpath "$p"
}

covers() { # dir, path → true when path is dir itself or inside it
  [ "$1" = / ] || [ "$1" = "$2" ] || case "$2" in "$1"/*) return 0 ;; *) return 1 ;; esac
}

# Decide whether deleting an existing local path loses anything git can't bring
# back: untracked or modified files, or ignored files that are not build/cache
# output. find mode drops ignored files from the count, because find's -name
# filter usually targets exactly those.
recoverable() { # absolute path, path as written, mode (rm|find)
  local a="$1" w="$2" mode="$3" d top st left
  if [ -d "$a" ]; then d=$a; else d=${a%/*}; d=${d:-/}; fi
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$top" ] || decide deny "pretool-guard: '$w' is not in a git repository, so deleting it cannot be undone. Move it to the Trash instead (mv $w ~/.Trash/), or work under /tmp."
  if [ "$top" = "$a" ] && [ -d "$a/.git" ]; then
    decide deny "pretool-guard: '$w' is a whole git repository, history included. Blocked — leave this one for the owner."
  fi
  st=$(git -C "$d" status --porcelain --ignored -- "$a" 2>/dev/null)
  if [ "$mode" = find ]; then
    left=$(printf '%s\n' "$st" | grep -v '^!! ' | grep -v '^$' | head -3)
  else
    left=$(printf '%s\n' "$st" | grep -vE "^!! (.*/)?($EPH)(/.*)?$" | grep -v '^$' | head -3)
  fi
  [ -z "$left" ] && return 0
  decide deny "pretool-guard: '$w' holds files git cannot bring back ($(printf '%s' "$left" | tr '\n' ' ')). Commit them first, or move it to the Trash (mv $w ~/.Trash/)."
}

check_target() { # cwd, target as written, mode (rm|find)
  local c="$1" raw="$2" mode="$3" w a base glob=0
  w=$(resolve_word "$raw")

  # Unrecoverable: filesystem root, home itself, or the whole current tree.
  if [ "$mode" = rm ]; then
    case "$w" in
      /|'~'|'~/'|'$HOME'|'$HOME/'|.|./|..|../|'*'|'./*')
        decide deny "pretool-guard: 'rm -r $w' would remove everything under it and has no targeted alternative. Blocked — name the specific path you mean." ;;
    esac
  fi
  case "$w" in
    *'$'*|*'`'*) decide deny "pretool-guard: cannot tell what '$raw' points to (a shell variable set outside this command). Write the literal path so it can be checked." ;;
  esac

  # Build/cache output: by its last name when absolute, by any part when relative.
  base=${w%/}
  case "$base" in
    /*|'~'/*|'$HOME'/*) printf '%s' "${base##*/}" | grep -qE "^($EPH)$" && return 0 ;;
    *) printf '%s' "$base" | grep -qE "(^|/)($EPH)(/|$)" && return 0 ;;
  esac

  # Another machine (ssh): only its temp dirs are allowed; nothing there can be
  # checked against git from here.
  if [ "$REMOTE" -eq 1 ]; then
    case "$w" in /tmp/?*|/var/tmp/?*|/private/tmp/?*) return 0 ;; esac
    decide deny "pretool-guard: '$w' is on another machine, so it cannot be checked against git there. Move it under /tmp on that machine first, or leave it for the owner."
  fi

  a=$(to_abs "$c" "$w")
  [ "$a" = "?" ] && decide deny "pretool-guard: cannot tell which directory '$w' is relative to (an earlier cd used a variable). Use an absolute path."
  case "$a" in
    /tmp/?*|/private/tmp/?*|/var/folders/?*|/private/var/folders/?*) return 0 ;;
  esac

  # A wildcard deletes from the directory that holds it; judge that directory.
  case "$a" in
    *'*'*|*'?'*|*'['*) glob=1; a=${a%%[*?[]*}; a=${a%/*}; a=${a:-/} ;;
  esac
  covers "$a" "$HOME" && decide deny "pretool-guard: '$w' contains your home directory. Blocked."
  if [ "$mode" = rm ] && [ "$glob" -eq 0 ] && [ "$c" != "?" ] && covers "$a" "$c"; then
    decide deny "pretool-guard: '$w' is the directory this command runs in, or contains it. Blocked — name what inside it you mean."
  fi

  [ -e "$a" ] || return 0   # nothing there to lose
  recoverable "$a" "$w" "$mode"
}

# ------------------------------------------------ recursive delete (rm, find)
# Walk the words once. Track `cd` so relative paths resolve against the right
# directory, note ssh (paths after it are on another machine), and collect the
# targets of every recursive `rm` — all of them, not just the last one.
TAB='	'
NL='
'
REMOTE=0; ECWD=$CWD
RM=0; REC=0; GROUP=""; ENTRIES=""
FIND=0; FIND_ROOT=.; FIND_CWD=$CWD
EXPECT=""; SKIPNEXT=0; PREV=""

end_group() {
  local t
  if [ "$RM" -eq 1 ] && [ "$REC" -eq 1 ]; then
    for t in $GROUP; do ENTRIES="$ENTRIES$ECWD$TAB$t$NL"; done
  fi
  RM=0; REC=0; GROUP=""
}

word() {
  local w="$1" r
  [ -z "$w" ] && return
  if [ "$EXPECT" = cd ]; then
    EXPECT=""
    r=$(resolve_word "$w")
    if [ "$REMOTE" -eq 1 ]; then ECWD='?'
    else case "$r" in *'$'*|*'`'*|-) ECWD='?' ;; *) ECWD=$(to_abs "$ECWD" "$r") ;; esac
    fi
    return
  fi
  if [ "$EXPECT" = findroot ]; then
    EXPECT=""
    case "$w" in -*|'!'|'('|'\(') ;; *) FIND_ROOT=$w; return ;; esac
  fi
  if [ "$SKIPNEXT" -eq 1 ]; then SKIPNEXT=0; return; fi
  case "$w" in ssh|*/ssh) REMOTE=1 ;; esac
  if [ "$RM" -eq 0 ]; then
    case "$w" in
      cd) EXPECT=cd; return ;;
      find) FIND=1; FIND_CWD=$ECWD; FIND_ROOT=.; EXPECT=findroot; return ;;
    esac
  fi
  case "$w" in
    rm|*/rm) end_group; [ "$PREV" = git ] || RM=1; return ;;   # `git rm` only unstages or deletes tracked files
  esac
  [ "$RM" -eq 1 ] || return
  case "$w" in
    '>'|'>>'|'2>'|'2>>'|'<'|'&>') SKIPNEXT=1 ;;               # redirection: the next word is its file
    *'>'*|*'<'*|--) ;;
    --recursive) REC=1 ;;
    --*) ;;
    # `-*[rR]*` and not `-[a-zA-Z]*[rR]*`: in `-rf` the r IS the first flag
    # character, so requiring a letter before it matches nothing.
    -*[rR]*) REC=1 ;;
    -*) ;;
    *) GROUP="$GROUP $w" ;;
  esac
}

for w in $N; do
  case "$w" in
    '&&'|'||'|';'|'|'|'&'|'('|')'|'{'|'}'|then|do|done|else|elif|fi|esac)
      end_group; EXPECT=""; PREV=""; continue ;;
  esac
  end=0
  case "$w" in *';'|*')') w=${w%[;)]}; w=${w%[;)]}; end=1 ;; esac
  case "$w" in '('*) w=${w#\(} ;; esac
  word "$w"
  PREV=$w
  if [ "$end" -eq 1 ]; then end_group; EXPECT=""; PREV=""; fi
done
end_group

if [ -n "$ENTRIES" ]; then
  while IFS="$TAB" read -r c t; do
    [ -n "$t" ] && check_target "$c" "$t" rm
  done <<EOF
$ENTRIES
EOF
fi

# find -delete / -exec rm: same blast radius, different spelling. Judged by the
# directory find starts from.
if [ "$FIND" -eq 1 ] && m '(-delete|-exec(dir)? +rm)'; then
  check_target "$FIND_CWD" "$FIND_ROOT" find
fi

# ------------------------------------------------------------------ DENY tier
# Filesystem / host
m 'mkfs\.'                                    && decide deny "pretool-guard: filesystem format — blocked."
m 'dd +.*of=/dev/'                            && decide deny "pretool-guard: raw write to block device — blocked."
m '> */dev/(sd|nvme|disk|hd)'                 && decide deny "pretool-guard: redirect over block device — blocked."
m 'chmod +-R +777 +/'                         && decide deny "pretool-guard: recursive 777 on / — blocked."
m ':\(\) *\{ *: *\| *: *& *\} *;:'            && decide deny "pretool-guard: fork bomb — blocked."
# Only in command position: `grep reboot syslog` is a search, not a reboot.
m '(^|[;&|(] *|sudo +|ssh +[^ ]+ +)(shutdown|reboot|halt|poweroff)\b|systemctl +(reboot|poweroff|halt)\b' && decide deny "pretool-guard: host power control — blocked."

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

# Docker: volumes are data, and "every unused image" includes rollback images.
# A plain prune only drops what can be rebuilt, so it passes.
m "${CP}docker +[^;&|]*(volume +prune|prune +[^;&|]*--volumes|(system|image) +prune +[^;&|]*(-a\b|--all))" && decide deny "pretool-guard: this prune removes volumes (data) or every unused image (rollback images included). Remove the specific image or volume by name instead."

# Git: force-push, unless it is the safe variant
if m "${CP}git +(-C +[^ ]+ +)?push( +[^;&|]*)? +(--force|-f)\b"; then
  m "${CP}git +(-C +[^ ]+ +)?push +[^;&|]*--force-with-lease" || decide deny "pretool-guard: force push — blocked. Use --force-with-lease."
fi

# Git discards: allowed when there is nothing to lose or a stash comes first in
# the same command; otherwise blocked with the fix. `git branch -D` is not
# gated: the reflog keeps its commits for 90 days.
git_dir() { # directory the git command runs in; "?" if unknowable
  local p
  p=$(printf '%s' "$N" | grep -oE 'git +-C +[^ ;&|]+' | head -1 | sed -E 's/^git +-C +//')
  if [ -z "$p" ]; then printf '%s' "$ECWD"; return; fi
  p=$(resolve_word "$p")
  case "$p" in *'$'*|*'`'*) printf '?' ;; *) to_abs "$ECWD" "$p" ;; esac
}

discard_check() { # what is lost (tracked|untracked|all), what the command is
  local kind="$1" what="$2" d st left
  m 'git +(-C +[^ ]+ +)?stash' && return 0
  [ "$REMOTE" -eq 1 ] && decide deny "pretool-guard: $what on another machine cannot be checked from here. Put git stash -u before it in the same command."
  d=$(git_dir)
  [ "$d" = "?" ] && decide deny "pretool-guard: cannot tell which repository this $what runs in. Use git -C with a literal path."
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || return 0   # not a repo: git refuses on its own
  if [ "$kind" = all ]; then st=$(git -C "$d" status --porcelain --ignored 2>/dev/null)
  else st=$(git -C "$d" status --porcelain 2>/dev/null); fi
  case "$kind" in
    tracked)   left=$(printf '%s\n' "$st" | grep -vE '^(\?\?|!!) ' | grep -v '^$' | head -3) ;;
    untracked) left=$(printf '%s\n' "$st" | grep -E '^\?\? ' | head -3) ;;
    all)       left=$(printf '%s\n' "$st" | grep -E '^(\?\?|!!) ' | grep -vE "^!! (.*/)?($EPH)(/.*)?$" | head -3) ;;
  esac
  [ -z "$left" ] && return 0
  decide deny "pretool-guard: $what would throw away work git cannot restore ($(printf '%s' "$left" | tr '\n' ' ')). Put git stash -u before it in the same command."
}

m "${CP}git +(-C +[^ ]+ +)?reset\b[^;&|]*--hard"              && discard_check tracked "git reset --hard"
m "${CP}git +(-C +[^ ]+ +)?checkout +(-- +)?\.( |;|$)"        && discard_check tracked "git checkout ."
# Same discard, different spelling: `checkout -f`, `switch -f`/`--discard-changes`
# and `restore .` all throw the worktree away without saying `reset --hard`.
# `restore --staged .` only unstages, so it stays allowed.
m "${CP}git +(-C +[^ ]+ +)?checkout\b[^;&|]* +(-[a-zA-Z]*f\b|--force\b)" && discard_check tracked "git checkout --force"
m "${CP}git +(-C +[^ ]+ +)?switch\b[^;&|]* +(-[a-zA-Z]*f\b|--force\b|--discard-changes\b)" && discard_check tracked "git switch --discard-changes"
if m "${CP}git +(-C +[^ ]+ +)?restore\b[^;&|]* +\.( |;|$)"; then
  # Worktree is touched unless `--staged` alone is given.
  if m "${CP}git +(-C +[^ ]+ +)?restore\b[^;&|]* +(-W\b|--worktree\b)" \
     || ! m "${CP}git +(-C +[^ ]+ +)?restore\b[^;&|]* +(-S\b|--staged\b)"; then
    discard_check tracked "git restore ."
  fi
fi
if m "${CP}git +(-C +[^ ]+ +)?clean +(-[a-zA-Z]*f|--force\b)"; then
  if m "${CP}git +(-C +[^ ]+ +)?clean +-[a-zA-Z]*[xX]"; then discard_check all "git clean -x"
  else discard_check untracked "git clean"; fi
fi

# ------------------------------------------------------------------- ASK tier
m 'kubectl +.*delete '        && decide ask "pretool-guard: this deletes a live Kubernetes resource. Confirm?"
m 'terraform +apply'          && decide ask "pretool-guard: terraform apply mutates real infrastructure. Confirm?"
m '(npm +publish|cargo +publish|twine +upload|gh +release +create)' && decide ask "pretool-guard: this publishes externally and cannot be unpublished cleanly. Confirm?"

exit 0
