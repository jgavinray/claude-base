#!/usr/bin/env bash
# Arm a repository: install .claude/verify.sh and seed CLAUDE.md.
#
#   ./init-repo.sh [path]          copy the verifier (self-contained, default)
#   ./init-repo.sh [path] --link   symlink it (updates propagate; breaks if
#                                  claude-base moves or the repo is cloned elsewhere)
#
# Never overwrites an existing CLAUDE.md or checks.sh.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"
MODE="${2:-copy}"
[ "$MODE" = "--link" ] && MODE=link

[ -d "$TARGET" ] || { echo "init-repo: no such directory: $TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

mkdir -p "$TARGET/.claude"

if [ "$MODE" = "link" ]; then
  ln -sf "$SRC/verify/verify.sh" "$TARGET/.claude/verify.sh"
  echo "  linked .claude/verify.sh -> $SRC/verify/verify.sh"
else
  cp "$SRC/verify/verify.sh" "$TARGET/.claude/verify.sh"
  chmod +x "$TARGET/.claude/verify.sh"
  echo "  copied .claude/verify.sh"
fi

if [ -f "$TARGET/CLAUDE.md" ]; then
  echo "  CLAUDE.md exists — left alone"
else
  cp "$SRC/templates/project-CLAUDE.md" "$TARGET/CLAUDE.md"
  echo "  seeded CLAUDE.md (fill it in)"
fi

# Report honestly whether this repo now has a real gate.
echo ""
CHECKS=$(cd "$TARGET" && ./.claude/verify.sh --list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
if [ -z "$CHECKS" ] || [ "$CHECKS" = "NONE" ]; then
  cat <<EOF
GATE INERT in $TARGET
  Nothing was auto-detected, so a green verifier here proves nothing.
  Add real checks to .claude/checks.sh (exit 0 = pass), for example:

    #!/usr/bin/env bash
    set -euo pipefail
    kustomize build overlays/prod >/dev/null
    kubeconform -strict -summary manifests/

  Then: chmod +x .claude/checks.sh
EOF
else
  echo "GATE ARMED in $TARGET"
  echo "  checks: $CHECKS"
fi
