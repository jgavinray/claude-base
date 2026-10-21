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

# Shadow call (10/20/2026): send the command, secrets masked, to the local Jev
# service in the background so its answers can be spot-checked later. It never
# waits and never changes a decision below. Skipped while
# ~/.claude/jev-shadow-off exists. See hooks/jev-shadow.sh.
JEV_SHADOW="${0%/*}/jev-shadow.sh"
if [ ! -e "${JEV_SHADOW_OFF_FILE:-$HOME/.claude/jev-shadow-off}" ] && [ -x "$JEV_SHADOW" ]; then
  { printf '%s' "$CMD" | "$JEV_SHADOW"; } >/dev/null 2>&1 </dev/null &
fi

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

# Global flags that may sit between a tool and its subcommand
# (`terraform -chdir=infra destroy`, `helm -n prod uninstall web`). One
# iteration is a dash-prefixed flag followed by an optional separate value (a
# word not starting with `-`), so `--namespace prod` and `--profile=prod` both
# match. Tokens exclude `; & |`, so the group cannot spill into a later command.
GF='(--?[A-Za-z][^ ;&|]* +([^ ;&|-][^ ;&|]* +)?)*'

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

# Scratch that may be deleted whole, with no git check (10/21/2026): the system
# temp dirs, Claude scratchpads (under /private/tmp), the runner's worktree
# folder, and any path listed one per line in ~/.claude/guard-ephemeral. These
# held copies the session itself made, and refusing them handed every cleanup
# to the owner as a manual command.
physpath() { # absolute path → same path with every symlink resolved; unchanged if its folder does not exist
  local p="$1" i=0 t d b
  while [ "$i" -lt 20 ] && [ -L "$p" ]; do
    t=$(readlink "$p")
    case "$t" in /*) p=$t ;; *) p="${p%/*}/$t" ;; esac
    p=$(normpath "$p"); i=$((i + 1))
  done
  d=${p%/*}; b=${p##*/}
  if [ -d "${d:-/}" ] && d=$(cd -P "${d:-/}" 2>/dev/null && pwd -P); then
    [ "$d" = / ] && d=""
    printf '%s/%s' "$d" "$b"
  else
    printf '%s' "$p"
  fi
}

# Roots in which anything below the root (not the root itself) is scratch.
scratch_roots() {
  local t=${TMPDIR:-}
  printf '%s\n' /tmp /private/tmp "$HOME/.cache/runner/work"
  [ -n "${t%/}" ] && printf '%s\n' "${t%/}"
}

# Under a root, or equal to a listed path. Roots covering / or home are ignored
# so a bad TMPDIR or a bad list line cannot open up everything.
in_scratch() { # absolute path
  local a="$1" root r f line
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for r in "$root" "$(physpath "$root")"; do
      covers "$r" "$HOME" && continue
      case "$a" in "$r"/?*) return 0 ;; esac
    done
  done <<EOF2
$(scratch_roots)
EOF2
  [[ "$a" =~ ^(/private)?/var/folders/[^/]+/[^/]+/T/.+ ]] && return 0
  f=${GUARD_EPHEMERAL_FILE:-$HOME/.claude/guard-ephemeral}
  if [ -r "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
      case "$line" in '~'/*) line="$HOME/${line#\~/}" ;; /*) ;; *) continue ;; esac
      line=$(normpath "$line")
      for r in "$line" "$(physpath "$line")"; do
        covers "$r" "$HOME" && continue
        covers "$r" "$a" && return 0
      done
    done < "$f"
  fi
  return 1
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

# A path on another machine that ~/.claude/guard-ephemeral lists for that host
# as a line `host:<ip-or-alias>:<absolute path>` (10/21/2026): the path and
# anything under it may be deleted over ssh. The host must match the word after
# ssh exactly (an alias does not stand for its IP). Lines for `/`, a top-level
# directory, or a home directory are ignored, as are `..` escapes.
remote_listed() { # host, path as written
  local host="$1" w="$2" f line h p
  [ -n "$host" ] && [ "$host" != - ] || return 1
  case "$w" in /*) ;; *) return 1 ;; esac
  w=$(normpath "$w")
  f=${GUARD_EPHEMERAL_FILE:-$HOME/.claude/guard-ephemeral}
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    case "$line" in host:*) ;; *) continue ;; esac
    line=${line#host:}; h=${line%%:*}; p=${line#*:}
    [ "$h" = "$host" ] || continue
    case "$p" in /*) ;; *) continue ;; esac
    p=$(normpath "$p")
    [ "$p" = / ] && continue
    [[ "$p" =~ ^/[^/]+$ ]] && continue
    [[ "$p" =~ ^/(home|Users|root)/[^/]+$ ]] && continue
    covers "$p" "$w" && return 0
  done < "$f"
  return 1
}

# Build/cache output is deletable when nothing live is in it.
regen_check() { # cwd, path as written; decides deny itself, returns when fine
  local a hit
  a=$(to_abs "$1" "$2")
  [ "$a" = "?" ] && return 0
  [ -e "$a" ] || return 0
  in_scratch "$a" && return 0
  a=$(physpath "$a")
  if lsof -w -d cwd,txt -Fn 2>/dev/null | awk -v a="$a" '/^n/ { p = substr($0, 2); if (p == a || index(p, a "/") == 1) { f = 1; exit } } END { exit !f }'; then
    decide deny "pretool-guard: '$2' has a running process with its program or working directory inside it, so it is not just build output (a live install?). Stop that process the proper way first, or leave it for the owner."
  fi
  hit=$(find "$a" -maxdepth 3 \( -name node_modules -o -name site-packages -o -name .git \) -prune -o \( -name '*.conf' -o -type d -name etc \) -print -quit 2>/dev/null)
  if [ -n "$hit" ]; then
    decide deny "pretool-guard: '$2' looks like build output but holds configuration ($hit). Those files may be the owner's and cannot be regenerated. Move them out, or leave it for the owner."
  fi
  return 0
}

check_target() { # cwd, target as written, mode (rm|find), [ssh host]
  local c="$1" raw="$2" mode="$3" host="${4:--}" w a base glob=0 eph
  w=$(resolve_word "$raw")

  # Unrecoverable: filesystem root, home itself, or the whole current tree.
  if [ "$mode" = rm ]; then
    case "$w" in
      /|'~'|'~/'|'$HOME'|'$HOME/'|.|./|..|../|'*'|'./*')
        decide deny "pretool-guard: 'rm -r $w' would remove everything under it and has no targeted alternative. Blocked — name the specific path you mean." ;;
    esac
  fi
  # $TMPDIR is the session's own temp dir; read it from the environment.
  if [ -n "${TMPDIR:-}" ]; then
    case "$w" in
      '$TMPDIR') w=${TMPDIR%/} ;;
      '${TMPDIR}') w=${TMPDIR%/} ;;
      '$TMPDIR'/*) w="${TMPDIR%/}/${w#'$TMPDIR'/}" ;;
      '${TMPDIR}'/*) w="${TMPDIR%/}/${w#'${TMPDIR}'/}" ;;
    esac
  fi
  case "$w" in
    *'$'*|*'`'*) decide deny "pretool-guard: cannot tell what '$raw' points to (a shell variable set outside this command). Write the literal path so it can be checked." ;;
  esac

  # Build/cache output: by its last name when absolute, by any part when relative.
  # A regenerable name is not enough (10/21/2026): `env/dist` under a live
  # AzerothCore install holds the running binaries and the owner's configs.
  # Locally the directory must have no running process in it and no *.conf or
  # etc/ below it; on another machine the guard cannot look, so a name alone
  # allows nothing there (a `host:` line in guard-ephemeral or /tmp does).
  base=${w%/}
  eph=0
  case "$base" in
    /*|'~'/*|'$HOME'/*) printf '%s' "${base##*/}" | grep -qE "^($EPH)$" && eph=1 ;;
    *) printf '%s' "$base" | grep -qE "(^|/)($EPH)(/|$)" && eph=1 ;;
  esac
  if [ "$eph" -eq 1 ] && [ "$REMOTE" -eq 0 ]; then
    regen_check "$c" "$w"
    return 0
  fi

  # Another machine (ssh): only its temp dirs are allowed; nothing there can be
  # checked against git from here.
  if [ "$REMOTE" -eq 1 ]; then
    case "$w" in /tmp/?*|/var/tmp/?*|/private/tmp/?*) return 0 ;; esac
    remote_listed "$host" "$w" && return 0
    decide deny "pretool-guard: '$w' is on another machine, so it cannot be checked (not against git, not for running processes, not for configs). Even a build-output name like dist or venv can be a live install there. Move it under /tmp on that machine first, or leave it for the owner."
  fi

  a=$(to_abs "$c" "$w")
  [ "$a" = "?" ] && decide deny "pretool-guard: cannot tell which directory '$w' is relative to (an earlier cd used a variable). Use an absolute path."
  # Scratch is judged by where it really is: a symlink in /tmp that points into
  # home is judged as the home path it leads to.
  if in_scratch "$a"; then
    in_scratch "$(physpath "$a")" && return 0
    a=$(physpath "$a")
  fi

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
REMOTE=0; RHOST=""; SSHSTATE=0; ECWD=$CWD
RM=0; REC=0; GROUP=""; ENTRIES=""
FIND=0; FIND_ROOT=.; FIND_CWD=$CWD
EXPECT=""; SKIPNEXT=0; PREV=""

end_group() {
  local t
  if [ "$RM" -eq 1 ] && [ "$REC" -eq 1 ]; then
    for t in $GROUP; do ENTRIES="$ENTRIES$ECWD$TAB$t$TAB${RHOST:--}$NL"; done
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
  # After `ssh`: skip its options (and their values) and take the first plain
  # word as the host, with any user@ cut off. Used by the host: lines of
  # ~/.claude/guard-ephemeral.
  if [ "$SSHSTATE" -eq 2 ]; then SSHSTATE=1; return; fi
  if [ "$SSHSTATE" -eq 1 ]; then
    case "$w" in
      -[bcDEeFIiJLlmOopQRSWw]) SSHSTATE=2 ;;
      -*) ;;
      *) RHOST=${w##*@}; SSHSTATE=0 ;;
    esac
    return
  fi
  case "$w" in ssh|*/ssh) REMOTE=1; SSHSTATE=1; RHOST="" ;; esac
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
  while IFS="$TAB" read -r c t h; do
    [ -n "$t" ] && check_target "$c" "$t" rm "$h"
  done <<EOF
$ENTRIES
EOF
fi

# find -delete / -exec rm: same blast radius, different spelling. Judged by the
# directory find starts from.
if [ "$FIND" -eq 1 ] && m '(-delete|-exec(dir)? +rm)'; then
  check_target "$FIND_CWD" "$FIND_ROOT" find "${RHOST:--}"
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
m "helm +${GF}(uninstall|delete) "             && decide deny "pretool-guard: helm uninstall — blocked. Use a targeted rollback."
m "argocd +${GF}app +delete"                    && decide deny "pretool-guard: argocd app delete — blocked."
m "flux +${GF}uninstall"                        && decide deny "pretool-guard: flux uninstall — blocked."

# Infrastructure as code
m "terraform +${GF}destroy"                     && decide deny "pretool-guard: terraform destroy — blocked."

# Cloud CLIs
m "aws +${GF}s3 +${GF}(rb|rm +[^;&|]*--recursive)" && decide deny "pretool-guard: recursive S3 delete — blocked."
m 'aws +.*delete-(cluster|bucket|stack|db-instance|table)' && decide deny "pretool-guard: AWS resource deletion — blocked."
m "az +${GF}group +delete"                      && decide deny "pretool-guard: Azure resource-group delete — blocked."
m 'gcloud +.*(projects|clusters|instances) +delete' && decide deny "pretool-guard: GCP resource deletion — blocked."

# Data
m '\b(truncate +table)\b' && decide deny "pretool-guard: destructive SQL — blocked."

# DROP DATABASE / DROP SCHEMA (10/21/2026): denied, except for a database the
# session made for itself and listed in ~/.claude/guard-ephemeral as a line
# `mysql-db:NAME`. The statement must be the whole SQL string (`-e "DROP
# DATABASE [IF EXISTS] NAME"`, backticks allowed), with exactly the listed name:
# no wildcard, no second statement, no unlisted name. Direct, `sudo mysql -e`
# and over ssh all read the same way. Remove the line when the drop is done.
mysql_drop_ok() {
  local f=${GUARD_EPHEMERAL_FILE:-$HOME/.claude/guard-ephemeral}
  [ -r "$f" ] || return 1
  printf '%s' "$CMD" | perl -e '
    my %ok; open(my $fh, "<", $ARGV[0]) or exit 1;
    while (<$fh>) { s/#.*//; $ok{$1} = 1 if /^\s*mysql-db:\s*([A-Za-z0-9_\$]+)\s*$/ }
    local $/; my $c = <STDIN>; $c = "" unless defined $c;
    my $total = () = $c =~ /\bdrop\s+(?:database|schema)\b/gi;
    my $good = 0;
    while ($c =~ /["\x27]\s*drop\s+(?:database|schema)\s+(?:if\s+exists\s+)?\x60?([A-Za-z0-9_\$]+)\x60?\s*;?\s*(?=\\?["\x27]|$)/gi) {
      exit 1 unless $ok{$1}; $good++ }
    exit(($total > 0 && $good == $total) ? 0 : 1);' "$f"
}
if m '\b(drop +database|drop +schema)\b'; then
  mysql_drop_ok || decide deny "pretool-guard: destructive SQL — blocked. A database you created for a test can be dropped once its name is on a line 'mysql-db:NAME' in ~/.claude/guard-ephemeral (one statement, exact name)."
fi

# Docker: volumes are data, and "every unused image" includes rollback images.
# A plain prune only drops what can be rebuilt, so it passes.
m "${CP}docker +[^;&|]*(volume +prune|prune +[^;&|]*--volumes|(system|image) +prune +[^;&|]*(-a\b|--all))" && decide deny "pretool-guard: this prune removes volumes (data) or every unused image (rollback images included). Remove the specific image or volume by name instead."

# Git: force-push, unless it is the safe variant.
# Global options before the subcommand (`-C dir`, `-c k=v`, `--no-pager`) are
# skipped, so `git --no-pager push -f` is still read as a push. A force is
# `--force`, a short-flag cluster holding f (`-f`, `-uf`, `-fu`), or a `+` at
# the start of a refspec (`git push origin +main`). A name like `feat+x` has
# the `+` mid-word and is not a forced ref.
GITG='( +(-C +[^ ;&|]+|-c +[^ ;&|]+|--no-pager|--paginate|-p|--bare|--git-dir=[^ ;&|]*|--work-tree=[^ ;&|]*))*'
GPUSH="${CP}git${GITG} +push\b"
if m "${GPUSH}[^;&|]*( +-[A-Za-z]*f[A-Za-z]*\b| +\+[^ ;&|]+| +--force\b)"; then
  m "${GPUSH}[^;&|]*--force-with-lease" || decide deny "pretool-guard: force push — blocked. Use --force-with-lease."
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
m "terraform +${GF}apply"      && decide ask "pretool-guard: terraform apply mutates real infrastructure. Confirm?"
m "(npm +${GF}publish|cargo +${GF}publish|twine +upload|gh +release +create)" && decide ask "pretool-guard: this publishes externally and cannot be unpublished cleanly. Confirm?"

# ------------------------------------------------------------- scope check
# Commands the rules above allow, but which signal, stop or overwrite things
# outside this session's own workspace (10/21/2026). scope-check.sh denies
# signals to processes the session did not start and NVIDIA/driver/reboot
# commands aimed at hyper03 itself; everything else in its class list is sent to
# Jev in the background and only logged. Kill switch: ~/.claude/scope-check-off.
# Doc: wiki/scope-check.md.
SCOPE_CHECK="${0%/*}/scope-check.sh"
if [ -x "$SCOPE_CHECK" ] && [ ! -e "${SCOPE_CHECK_OFF_FILE:-$HOME/.claude/scope-check-off}" ]; then
  SCOPE_OUT=$(printf '%s' "$INPUT" | "$SCOPE_CHECK" 2>/dev/null) || SCOPE_OUT=""
  if [ -n "$SCOPE_OUT" ] && printf '%s' "$SCOPE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf '%s\n' "$SCOPE_OUT"
    exit 0
  fi
fi

exit 0
