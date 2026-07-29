#!/usr/bin/env bash
# PostToolUse (Edit|Write): fast syntax check on the file just written, and
# record that this session has edited something (the Stop gate keys off it).
#
# Exit 2 => stderr is fed back to the model immediately. The write already
# happened; this surfaces the error at write time instead of at the gate.
#
# HARD RULE: every check here must be near-instant. Anything that compiles,
# resolves dependencies, or hits the network belongs in verify.sh, not here.
set -u

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')

# Arm the Stop gate for this session, whatever the file type.
: > "${TMPDIR:-/tmp}/claude-base-edited-${SESSION_ID}"

{ [ -z "$FILE" ] || [ ! -f "$FILE" ]; } && exit 0

fail() { echo "post-edit-check [$FILE]: $1" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

case "$FILE" in
  *.py)
    ERR=$(python3 -m py_compile "$FILE" 2>&1) || fail "python syntax error: $ERR"
    if have ruff; then
      ERR=$(ruff check --quiet "$FILE" 2>&1) || fail "ruff: $ERR"
    fi
    ;;
  *.sh|*.bash)
    ERR=$(bash -n "$FILE" 2>&1) || fail "bash syntax error: $ERR"
    ;;
  *.json)
    have jq && { ERR=$(jq empty "$FILE" 2>&1) || fail "invalid JSON: $ERR"; }
    ;;
  *.yaml|*.yml)
    # Go-templated files (Helm) are not YAML until rendered — skip them.
    if ! grep -q '{{' "$FILE" 2>/dev/null; then
      if have yq; then
        ERR=$(yq e 'true' "$FILE" 2>&1 >/dev/null) || fail "invalid YAML: $ERR"
      elif have python3; then
        ERR=$(python3 -c "import sys,yaml;list(yaml.safe_load_all(open(sys.argv[1])))" "$FILE" 2>&1) \
          || fail "invalid YAML: $ERR"
      fi
    fi
    ;;
  *.toml)
    have python3 && {
      ERR=$(python3 -c "import sys,tomllib;tomllib.load(open(sys.argv[1],'rb'))" "$FILE" 2>&1) \
        || fail "invalid TOML: $ERR"
    }
    ;;
  *.go)
    have gofmt && { ERR=$(gofmt -l -e "$FILE" 2>&1) || fail "gofmt: $ERR"; }
    ;;
  *.rs)
    have rustfmt && { ERR=$(rustfmt --check --edition 2021 "$FILE" 2>&1) || fail "rustfmt: $ERR"; }
    ;;
  *.tf)
    have terraform && { ERR=$(terraform fmt -check "$FILE" 2>&1) || fail "terraform fmt: $ERR"; }
    ;;
  *.jsonnet|*.libsonnet)
    have jsonnetfmt && { ERR=$(jsonnetfmt --test "$FILE" 2>&1) || fail "jsonnetfmt: $ERR"; }
    ;;
esac
exit 0
