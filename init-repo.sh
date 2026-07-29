#!/usr/bin/env bash
# Arm a repository: install .claude/verify.sh, seed CLAUDE.md, and record a
# baseline of what is ALREADY failing so the gate measures regression rather
# than absolute green.
#
#   ./init-repo.sh [path]                copy the verifier (self-contained, default)
#   ./init-repo.sh [path] --link         symlink it instead (updates propagate)
#   ./init-repo.sh [path] --local        keep .claude/ out of git (.git/info/exclude)
#   ./init-repo.sh [path] --no-baseline  arm strictly; pre-existing failures block
#
# Baselining is what makes this safe on a fork you are upstreaming to, or on any
# older repo carrying lint debt: upstream's existing failures are recorded and
# reported but do not block, while anything YOU break does. Refusing to arm such
# repos would be backwards — a change you intend to send upstream needs the gate
# more than average, not less.
#
# Never overwrites an existing CLAUDE.md, checks.sh, or baseline.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="."
MODE="copy"
LOCAL=0
BASELINE=1

for arg in "$@"; do
  case "$arg" in
    --link)        MODE=link ;;
    --local)       LOCAL=1 ;;
    --no-baseline) BASELINE=0 ;;
    -*)            echo "init-repo: unknown flag $arg" >&2; exit 64 ;;
    *)             TARGET="$arg" ;;
  esac
done

[ -d "$TARGET" ] || { echo "init-repo: no such directory: $TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

mkdir -p "$TARGET/.claude"

if [ "$MODE" = "link" ]; then
  ln -sf "$SRC/verify/verify.sh" "$TARGET/.claude/verify.sh"
  echo "  linked  .claude/verify.sh -> $SRC/verify/verify.sh"
else
  cp "$SRC/verify/verify.sh" "$TARGET/.claude/verify.sh"
  chmod +x "$TARGET/.claude/verify.sh"
  echo "  copied  .claude/verify.sh"
fi

if [ -f "$TARGET/CLAUDE.md" ]; then
  echo "  kept    CLAUDE.md (already present)"
else
  cp "$SRC/templates/project-CLAUDE.md" "$TARGET/CLAUDE.md"
  echo "  seeded  CLAUDE.md (fill it in)"
fi

# ---- keep the harness out of other people's diffs ---------------------------
# On a fork you contribute back to, .claude/ appearing in a pull request is noise
# at best and a review distraction at worst. .git/info/exclude is the right
# mechanism: local-only, never committed, and unlike .gitignore it does not
# itself show up as a change.
HAS_UPSTREAM=0
git -C "$TARGET" remote 2>/dev/null | grep -qx upstream && HAS_UPSTREAM=1

if [ "$LOCAL" -eq 1 ]; then
  EXCL="$TARGET/.git/info/exclude"
  mkdir -p "$(dirname "$EXCL")"
  if ! grep -qx '.claude/' "$EXCL" 2>/dev/null; then
    printf '.claude/\nCLAUDE.md\n' >> "$EXCL"
    echo "  ignored .claude/ + CLAUDE.md via .git/info/exclude (local only)"
  else
    echo "  ignored .claude/ already excluded locally"
  fi
elif [ "$HAS_UPSTREAM" -eq 1 ]; then
  echo "  NOTE    this repo has an 'upstream' remote — you are likely contributing back."
  echo "          Re-run with --local to keep .claude/ out of your PRs."
fi

# ---- what does "done" mean here, and does it currently hold? ----------------
echo ""
CHECKS=$(cd "$TARGET" && ./.claude/verify.sh --list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')

if [ -z "$CHECKS" ] || [ "$CHECKS" = "NONE" ]; then
  cat <<EOF
GATE INERT in $TARGET
  Nothing was auto-detected, so a green verifier here proves nothing.
  Add real checks to .claude/checks.sh (exit 0 = pass), for example:

    #!/usr/bin/env bash
    set -euo pipefail
    make test

  Then: chmod +x .claude/checks.sh && $0 $TARGET
EOF
  exit 0
fi

echo "Detected checks: $CHECKS"
echo "Running them once to establish the starting state..."
echo ""

AUDIT=$(cd "$TARGET" && ./.claude/verify.sh --audit 2>/dev/null || true)
FAILING=$(printf '%s\n' "$AUDIT" | awk '/^FAIL /{print $2}' | sort)

if [ -z "$FAILING" ]; then
  echo "GATE ARMED — currently GREEN."
  echo "  Every detected check passes. Any failure from here is something you introduced."
  exit 0
fi

COUNT=$(printf '%s\n' "$FAILING" | grep -c .)

if [ "$BASELINE" -eq 0 ]; then
  cat <<EOF
GATE ARMED (strict) — currently RED: $(printf '%s' "$FAILING" | tr '\n' ' ')

  $COUNT check(s) already fail and --no-baseline was passed, so the Stop gate
  will block immediately on work unrelated to them. That is usually not what you
  want on an inherited codebase. Re-run without --no-baseline to record them.
EOF
  exit 0
fi

if [ -f "$TARGET/.claude/baseline" ]; then
  echo "GATE ARMED — .claude/baseline already exists, left untouched."
  echo "  currently failing: $(printf '%s' "$FAILING" | tr '\n' ' ')"
  echo "  Delete it and re-run to re-baseline."
  exit 0
fi

{
  echo "# Checks already failing when this repo was armed."
  echo "# They are reported but do not block. Anything NOT listed here does."
  echo "# Delete a line once you have fixed it — a stale entry hides real regressions."
  printf '%s\n' "$FAILING"
} > "$TARGET/.claude/baseline"

cat <<EOF
GATE ARMED — currently RED, baseline recorded.

  Pre-existing failures ($COUNT), written to .claude/baseline:
$(printf '%s\n' "$FAILING" | sed 's/^/    - /')

  These will NOT block you — they came with the codebase. Anything you break
  beyond them will. Fix them when you can and delete the line; a stale baseline
  entry silently hides a real regression later.
EOF
