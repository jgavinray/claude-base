#!/usr/bin/env bash
# Remove the claude-base global layer from ~/.claude.
#
#   ./uninstall.sh --dry-run   show what would be removed
#   ./uninstall.sh             remove it
#
# Removes only what install.sh added: the four hook scripts, the five agents, the
# workflow skill, our CLAUDE.md, our four hook event registrations, and our
# permissions.deny entries. Anything else in settings.json is left alone.
#
# Deliberately NOT removed:
#   - `attribution` — suppressing commit trailers is a stated preference, not
#     claude-base scaffolding. Removing it would silently re-enable them.
#   - per-repo .claude/verify.sh, checks.sh, baseline, expected-checks — those
#     belong to their repos. `rm -r <repo>/.claude` when you want one gone.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '%s\n' "$1"; }
run() { if [ "$DRY" -eq 1 ]; then say "  would: $*"; else "$@"; fi; }

command -v jq >/dev/null 2>&1 || { echo "uninstall.sh: jq is required" >&2; exit 1; }

say "claude-base <- $DEST"

for f in "$SRC"/hooks/*.sh; do
  b=$(basename "$f")
  [ -e "$DEST/hooks/$b" ] && { run rm -f "$DEST/hooks/$b"; say "  hook: $b"; }
done
for f in "$SRC"/agents/*.md; do
  b=$(basename "$f")
  [ -e "$DEST/agents/$b" ] && { run rm -f "$DEST/agents/$b"; say "  agent: ${b%.md}"; }
done
[ -e "$DEST/skills/workflow/SKILL.md" ] && {
  run rm -rf "$DEST/skills/workflow"; say "  skill: workflow"
}

# Only remove CLAUDE.md if it is ours — an edited or unrelated one stays.
if [ -f "$DEST/CLAUDE.md" ] && grep -q 'Installed to `~/.claude/CLAUDE.md`' "$DEST/CLAUDE.md" 2>/dev/null; then
  run rm -f "$DEST/CLAUDE.md"; say "  rules: CLAUDE.md"
elif [ -f "$DEST/CLAUDE.md" ]; then
  say "  rules: CLAUDE.md left in place (modified or not ours)"
fi
[ -e "$DEST/CLAUDE.md.claude-base" ] && run rm -f "$DEST/CLAUDE.md.claude-base"

SETTINGS="$DEST/settings.json"
if [ -f "$SETTINGS" ]; then
  if [ "$DRY" -eq 1 ]; then
    say "  would: strip claude-base hooks + deny entries from settings.json"
  else
    cp "$SETTINGS" "$SETTINGS.bak"
    TMP=$(mktemp)
    jq -s '
      .[0] as $cur | .[1] as $ours
      | $cur
      # Drop hook entries whose command points at our scripts; drop the event
      # key entirely if nothing else was registered under it.
      | .hooks = (
          (.hooks // {})
          | with_entries(
              .value |= map(
                .hooks |= map(select((.command // "") | test("claude-base|\\.claude/hooks/(session-context|pretool-guard|post-edit-check|stop-gate)\\.sh") | not))
              )
              | .value |= map(select((.hooks | length) > 0))
            )
          | with_entries(select((.value | length) > 0))
        )
      | .permissions.deny = (((.permissions.deny // []) - ($ours.permissions.deny // [])) | unique)
      | if (.permissions.deny | length) == 0 then del(.permissions.deny) else . end
      | if (.permissions | length) == 0 then del(.permissions) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS" "$SRC/settings.json" > "$TMP"
    jq empty "$TMP" || { echo "uninstall.sh: produced invalid JSON, aborting" >&2; rm -f "$TMP"; exit 1; }
    mv "$TMP" "$SETTINGS"
    say "  settings: claude-base entries removed (backup at settings.json.bak)"
  fi
fi

say ""
say "Removed. 'attribution' was left in settings.json on purpose — it is your"
say "preference, not our scaffolding. Per-repo .claude/ directories are untouched."
