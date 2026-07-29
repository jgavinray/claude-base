#!/usr/bin/env bash
# claude-base generic verifier — the single definition of "done".
#
# Exit 0 = the Stop gate releases. Anything else = the agent keeps working.
#
# This file auto-detects the repo's toolchain and runs only what is present, so
# the same script is valid in a Go service and in a directory of Kubernetes
# manifests. For a manifest repo, `kustomize build` + schema validation IS the
# test suite — that is the point.
#
# Escape hatches, in order of preference:
#   .claude/checks.sh      — if present, runs IN ADDITION to detection (your repo-specific checks)
#   .claude/verify.local.sh — if present, REPLACES detection entirely
#
# --list prints what would run without running it (used by session-context.sh
# to tell you honestly whether the gate has teeth in this repo).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LIST=0
AUDIT=0
case "${1:-}" in
  --list)  LIST=1 ;;
  --audit) AUDIT=1 ;;   # run every check, report which fail, always exit 0
esac

have() { command -v "$1" >/dev/null 2>&1; }

# Detected checks, in run order. Each entry is "name<TAB>shell command".
CHECKS=()
add() { CHECKS+=("$1	$2"); }

# Python entry point: prefer the repo's virtualenv so the gate runs the same
# interpreter the human does. Both common directory names are checked.
VENV=""
for v in .venv venv env; do [ -x "$v/bin/python" ] && { VENV="$v"; break; }; done
PY="python3"
[ -n "$VENV" ] && PY="$VENV/bin/python"
pybin() { # tool name -> runnable path, empty if unavailable
  [ -n "$VENV" ] && [ -x "$VENV/bin/$1" ] && { echo "$VENV/bin/$1"; return; }
  have "$1" && { echo "$1"; return; }
  echo ""
}

# ---------------------------------------------------------------- full override
if [ -x .claude/verify.local.sh ]; then
  if [ "$LIST" -eq 1 ]; then echo "verify.local.sh (repo override)"; exit 0; fi
  exec .claude/verify.local.sh
fi

# ------------------------------------------------------------------- detection
# --- Python
if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; then
  RUFF=$(pybin ruff)
  [ -n "$RUFF" ] && add "ruff-check" "$RUFF check ."
  [ -n "$RUFF" ] && add "ruff-format" "$RUFF format --check ."
  PYRIGHT=$(pybin pyright)
  [ -n "$PYRIGHT" ] && [ -f pyrightconfig.json ] && add "pyright" "$PYRIGHT"
  PYTEST=$(pybin pytest)
  if [ -n "$PYTEST" ] && { [ -d tests ] || [ -d test ] || compgen -G "test_*.py" >/dev/null 2>&1; }; then
    add "pytest" "$PYTEST -q"
  fi
fi

# --- Go
if [ -f go.mod ]; then
  have gofmt && add "gofmt" "test -z \"\$(gofmt -l .)\""
  have go && add "go-vet" "go vet ./..."
  have go && add "go-test" "go test ./..."
fi

# --- Rust
if [ -f Cargo.toml ]; then
  have cargo && add "cargo-fmt" "cargo fmt --check"
  have cargo && add "cargo-clippy" "cargo clippy --all-targets --quiet -- -D warnings"
  have cargo && add "cargo-test" "cargo test --quiet"
fi

# --- Node
if [ -f package.json ] && have npm; then
  # Only run scripts that actually exist; npm's default test script is a stub
  # that exits 1 and would wedge the gate permanently.
  if have jq; then
    jq -e '.scripts.lint' package.json >/dev/null 2>&1 && add "npm-lint" "npm run lint --silent"
    jq -e '.scripts.test // "" | test("no test specified") | not' package.json >/dev/null 2>&1 \
      && add "npm-test" "npm test --silent"
    jq -e '.scripts.typecheck' package.json >/dev/null 2>&1 && add "npm-typecheck" "npm run typecheck --silent"
  fi
fi

# --- Terraform (fmt only; `validate` needs init/credentials and is not hermetic)
if compgen -G "*.tf" >/dev/null 2>&1 && have terraform; then
  add "tf-fmt" "terraform fmt -check -recursive"
fi

# --- Kubernetes: kustomize / helm / schema
if [ -f kustomization.yaml ] || [ -f kustomization.yml ]; then
  if have kustomize; then add "kustomize-build" "kustomize build . >/dev/null"
  elif have kubectl; then add "kustomize-build" "kubectl kustomize . >/dev/null"; fi
fi
if [ -f Chart.yaml ] && have helm; then
  add "helm-lint" "helm lint ."
  add "helm-template" "helm template . >/dev/null"
fi
if have kubeconform; then
  # Only manifests that look like k8s objects; -ignore-missing-schemas keeps CRDs
  # from turning every run red.
  add "kubeconform" "kubeconform -strict -summary -ignore-missing-schemas \
    \$(grep -rl --include='*.yaml' --include='*.yml' -e '^kind:' -e '^apiVersion:' . \
       --exclude-dir=.git --exclude-dir=templates --exclude-dir=node_modules 2>/dev/null | head -500) >/dev/null"
fi

# --- Jsonnet
if compgen -G "*.jsonnet" >/dev/null 2>&1 || compgen -G "*.libsonnet" >/dev/null 2>&1; then
  have jsonnetfmt && add "jsonnetfmt" "jsonnetfmt --test \$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.jsonnet' '*.libsonnet')"
fi

# --- Ansible
if [ -f ansible.cfg ] || compgen -G "playbook*.yml" >/dev/null 2>&1; then
  have ansible-lint && add "ansible-lint" "ansible-lint -q"
fi

# --- YAML validity (the fallback that gives manifest-only repos a real gate)
# Skips Helm templates and anything with Go-template markers — those are not YAML
# until rendered. Prefers yq; falls back to PyYAML.
#
# If NEITHER is installed we deliberately do not register the check, so the repo
# reports INERT rather than running a check that silently no-ops. A gate that
# skips is indistinguishable from a gate that passes, and that is the failure
# mode this whole design exists to prevent.
if [ -n "$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.yaml' '*.yml' 2>/dev/null | head -1)" ]; then
  if have yq; then
    add "yaml-parse" 'BAD=0
      for f in $(git ls-files -c -o --exclude-standard ":(exclude).claude/*" "*.yaml" "*.yml"); do
        case "$f" in templates/*|*/templates/*) continue;; esac
        grep -q "{{" "$f" 2>/dev/null && continue
        yq e "true" "$f" >/dev/null 2>&1 || { echo "$f: YAML parse error" >&2; BAD=1; }
      done
      exit $BAD'
  elif "$PY" -c "import yaml" >/dev/null 2>&1; then
    add "yaml-parse" "$PY \"\$CLAUDE_BASE_YAMLCHECK\""
  fi
fi

# --- Shell
if [ -n "$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.sh' 2>/dev/null | head -1)" ]; then
  add "sh-syntax" "for f in \$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.sh'); do bash -n \"\$f\" || exit 1; done"
  have shellcheck && add "shellcheck" "shellcheck -S warning \$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.sh')"
fi

# --- JSON validity
if have jq && [ -n "$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.json' 2>/dev/null | head -1)" ]; then
  add "json-parse" "for f in \$(git ls-files -c -o --exclude-standard ':(exclude).claude/*' '*.json'); do jq empty \"\$f\" || exit 1; done"
fi

# --- repo-specific additions
[ -x .claude/checks.sh ] && add "repo-checks" ".claude/checks.sh"

# ----------------------------------------------------------------------- --list
if [ "$LIST" -eq 1 ]; then
  if [ ${#CHECKS[@]} -eq 0 ]; then echo "NONE"; exit 0; fi
  for c in "${CHECKS[@]}"; do printf '%s\n' "${c%%	*}"; done
  exit 0
fi

# --------------------------------------------------------------- inert warning
if [ ${#CHECKS[@]} -eq 0 ]; then
  cat >&2 <<'EOF'
verify.sh: NO CHECKS RAN — this gate is INERT.
Nothing was detected and no .claude/checks.sh exists, so "done" is currently
undefined in this repo and the Stop gate cannot catch anything. Add real checks
to .claude/checks.sh (exit 0 = pass) before trusting a green result here.
EOF
  exit 0
fi

# --------------------------------------------------------------------- yamlcheck
# Written to a temp file so the check command stays a one-liner.
YAMLCHECK=$(mktemp "${TMPDIR:-/tmp}/claude-base-yamlcheck.XXXXXX.py")
trap 'rm -f "$YAMLCHECK"' EXIT
cat > "$YAMLCHECK" <<'PYEOF'
import subprocess, sys
import yaml  # registered only when importable — see the detection block
files = subprocess.run(["git","ls-files","-c","-o","--exclude-standard",":(exclude).claude/*","*.yaml","*.yml"],
                       capture_output=True, text=True).stdout.split()
bad = []
for f in files:
    try:
        text = open(f, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    if "{{" in text or "/templates/" in f or f.startswith("templates/"):
        continue  # Go-templated, not YAML until rendered
    try:
        list(yaml.safe_load_all(text))
    except yaml.YAMLError as e:
        first = str(e).splitlines()[0] if str(e) else "parse error"
        bad.append(f"{f}: {first}")
for b in sorted(bad):
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PYEOF
export CLAUDE_BASE_YAMLCHECK="$YAMLCHECK"

# --------------------------------------------------------------------- baseline
# `.claude/baseline` lists checks that were ALREADY failing when this repo was
# armed — pre-existing lint debt, or upstream failures in a fork you contribute
# to. Those are reported but do not block; anything NOT in the baseline does.
#
# The gate is therefore "no regression from a recorded starting point", not
# "absolute green". Absolute green is the special case where the baseline is
# empty, which is most repos and the state every repo should be moving toward.
BASELINE=""
[ -f .claude/baseline ] && BASELINE=$(grep -v '^#' .claude/baseline 2>/dev/null | grep -v '^[[:space:]]*$')
in_baseline() { printf '%s\n' "$BASELINE" | grep -qx -- "$1"; }

# --------------------------------------------------------------------- run them
FAILED=0
PREEXISTING=""
FIXED=""
for entry in "${CHECKS[@]}"; do
  name="${entry%%	*}"
  cmd="${entry#*	}"
  [ "$AUDIT" -eq 0 ] && printf '== %s\n' "$name"
  if OUT=$(LC_ALL=C bash -c "$cmd" 2>&1); then
    [ "$AUDIT" -eq 1 ] && printf 'PASS %s\n' "$name"
    in_baseline "$name" && FIXED="$FIXED $name"
    continue
  fi

  # Audit: report every failure, never block, never stop early.
  if [ "$AUDIT" -eq 1 ]; then
    printf 'FAIL %s\n' "$name"
    continue
  fi

  if in_baseline "$name"; then
    PREEXISTING="$PREEXISTING $name"
    echo "   (pre-existing failure, in .claude/baseline — not blocking)"
    continue
  fi

  printf '%s\n' "$OUT" | tail -40
  printf 'FAIL: %s\n' "$name" >&2
  FAILED=1
  break   # first NEW failure only: fix one thing at a time
done

[ "$AUDIT" -eq 1 ] && exit 0

if [ "$FAILED" -eq 0 ]; then
  echo "verify.sh: no regressions across ${#CHECKS[@]} check(s)"
  [ -n "$PREEXISTING" ] && echo "  still failing from baseline:$PREEXISTING"
  # A baselined check that now passes should leave the baseline, or it will hide
  # a real regression later.
  [ -n "$FIXED" ] && echo "  NOW PASSING — remove from .claude/baseline:$FIXED"
fi
exit "$FAILED"
