#!/usr/bin/env bash
# Install the claude-base global layer into ~/.claude.
#
# Global, not per-repo: hooks are installed once and apply to every repository,
# so 131 repos do not each carry a copy that drifts. The tradeoff is real and you
# should know it — a fresh clone on another machine is unguarded, and repo
# scanners cannot see hooks that live in your home directory.
#
# Only `verify.sh` and the project CLAUDE.md are per-repo; use init-repo.sh.
#
#   ./install.sh            install / update
#   ./install.sh --dry-run  show what would change
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '%s\n' "$1"; }
run() { if [ "$DRY" -eq 1 ]; then say "  would: $*"; else "$@"; fi; }

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

say "claude-base -> $DEST"

# ---- hooks, agents, skills ---------------------------------------------------
for d in hooks agents skills; do
  run mkdir -p "$DEST/$d"
done
for f in "$SRC"/hooks/*.sh; do
  run cp "$f" "$DEST/hooks/$(basename "$f")"
  run chmod +x "$DEST/hooks/$(basename "$f")"
  say "  hook: $(basename "$f")"
done
for f in "$SRC"/agents/*.md; do
  run cp "$f" "$DEST/agents/$(basename "$f")"
  say "  agent: $(basename "$f" .md)"
done

# ---- global CLAUDE.md --------------------------------------------------------
if [ -f "$DEST/CLAUDE.md" ] && ! grep -q 'Installed to `~/.claude/CLAUDE.md`' "$DEST/CLAUDE.md" 2>/dev/null; then
  say "  NOTE: $DEST/CLAUDE.md exists and is not ours — saved ours as CLAUDE.md.claude-base"
  run cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md.claude-base"
else
  run cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"
  say "  rules: CLAUDE.md"
fi

# ---- settings.json merge -----------------------------------------------------
# Replaces the four hook events we own (idempotent on re-run), preserves any
# other event keys and every unrelated setting. permissions.deny is unioned.
SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if [ "$DRY" -eq 1 ]; then
  say "  would: merge hooks + permissions.deny into $SETTINGS (backup first)"
else
  cp "$SETTINGS" "$SETTINGS.bak"
  TMP=$(mktemp)
  jq -s '
    .[0] as $cur | .[1] as $new
    | $cur
    | .hooks = ((.hooks // {}) + ($new.hooks))
    | .permissions = ((.permissions // {}) +
        {deny: (((.permissions.deny // []) + ($new.permissions.deny // [])) | unique)})
  ' "$SETTINGS" "$SRC/settings.json" > "$TMP"
  jq empty "$TMP" || { echo "install.sh: merge produced invalid JSON, aborting" >&2; rm -f "$TMP"; exit 1; }
  mv "$TMP" "$SETTINGS"
  say "  settings: merged (backup at settings.json.bak)"
fi

say ""
say "Global layer installed. Per repo, run:"
say "  $SRC/init-repo.sh <path-to-repo>"
say ""
say "Verify wiring with /hooks inside Claude Code."
