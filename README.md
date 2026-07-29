# claude-base

The enforcement floor for Claude Code, extracted from the `ai-harness` project's
harness and generalized. Roughly 300 lines of hooks plus one auto-detecting
verifier, installed once globally and armed per repo.

This is deliberately **not** the full harness. The pieces that drive local models
unattended overnight — task graphs, the `wf-run` driver, transcript corpora,
retro/proposal loops — stayed behind, because they earn their complexity only in
that setting. What's here is the part that is true in every repo.

## The one idea

An external program, not the model, decides whether work is done.

`.claude/verify.sh` exits 0 or it doesn't. The `Stop` hook reads that exit code
and refuses to let the session end while it's nonzero, injecting the failure
output as feedback. The model can't declare victory, and it can't talk its way
past a red check. Everything else here supports that.

The corollary matters just as much: **a gate that isn't armed must say so.** A
verifier that runs no checks and exits 0 is worse than no verifier, because it
reports green. `verify.sh --list` and the SessionStart hook both name that state
explicitly (`GATE INERT`), and the `verifier` agent reports `INERT` rather than
`PASS`.

## Layout

```
CLAUDE.md            global rules (~30 lines) -> ~/.claude/CLAUDE.md
settings.json        hook wiring + permissions.deny, merged into ~/.claude/settings.json
hooks/
  session-context.sh SessionStart: branch, dirty files, and whether the gate has teeth
  pretool-guard.sh   PreToolUse(Bash): two-tier deny/ask on destructive commands
  post-edit-check.sh PostToolUse(Edit|Write): instant syntax check; arms the Stop gate
  stop-gate.sh       Stop: blocks until verify.sh exits 0 (edit-triggered)
verify/verify.sh     the auto-detecting verifier -> <repo>/.claude/verify.sh
agents/              planner, qa-tester, verifier, code-reviewer, doc-manager
skills/workflow/     opt-in state machine for multi-step work
templates/           project CLAUDE.md skeleton
tests/base-test.sh   108 checks; claude-base gates itself with its own contract
install.sh           install the global layer
init-repo.sh         arm one repository
```

## Install

```bash
./install.sh --dry-run     # see what it would do
./install.sh               # ~/.claude/{hooks,agents,skills,CLAUDE.md} + settings merge
./init-repo.sh ~/dev/some-repo
```

`install.sh` backs up `settings.json` before merging, replaces only the four hook
events it owns, and unions `permissions.deny`. Re-running is idempotent.

**Global, not per-repo** — the inverse of the original harness's recommendation.
With one machine and 100+ repos, copying four scripts into each one guarantees
drift. The tradeoff is real: a fresh clone elsewhere is unguarded, and repo
scanners can't see hooks in `$HOME`. If a specific repo needs to carry its own
harness, copy `hooks/` into it and switch the paths back to `$CLAUDE_PROJECT_DIR`.

Requires `jq`. Verify wiring with `/hooks` inside Claude Code.

## The verifier

`verify/verify.sh` detects the toolchain and runs only what's present, so one
script is valid in a Go service and in a directory of Kubernetes manifests. For a
manifest repo, `kustomize build` + schema validation **is** the test suite.

Detected: ruff/pytest/pyright · gofmt/vet/test · cargo fmt/clippy/test ·
npm lint/test/typecheck · terraform fmt · kustomize · helm lint+template ·
kubeconform · jsonnetfmt · ansible-lint · YAML parse (yq or PyYAML) ·
shell syntax + shellcheck · JSON parse.

Two escape hatches:

- `.claude/checks.sh` — your repo-specific checks, run **in addition** to detection.
- `.claude/verify.local.sh` — **replaces** detection entirely.

Checks stop at the first failure, so the model fixes one thing at a time.

A check is only registered when its tool is actually installed. If nothing is
installed, the repo reports INERT rather than running a check that silently
no-ops — a gate that skips is indistinguishable from a gate that passes, and
that's the failure this whole design exists to prevent.

## Two things that differ from the original harness

**The Stop gate is edit-triggered.** `post-edit-check.sh` drops a
session-keyed marker; `stop-gate.sh` exits immediately when there isn't one. The
original ran the full verifier on every stop event, including answering a
question — unusable in a repo whose verifier renders 200 manifests.

**The guard has two tiers.** DENY for the unrecoverable (namespace deletion,
`terraform destroy`, `helm uninstall`, PV/PVC deletion, force-push without
`--force-with-lease`, cloud resource deletion). ASK for the destructive-but-useful
(`kubectl delete <resource>`, `terraform apply`, `git reset --hard`, publishes).
The original blocked `rm -rf /` and nothing that touches a cluster.

It is a denylist over command text, so it is a **floor, not a fence** —
obfuscation, shell variables, and scripts-calling-scripts defeat it by
construction. It protects against accidents, never against a determined process.
It matters more than usual when `skipDangerousModePermissionPrompt` is set,
because then it is the only thing in the path.

## What was intentionally left out

- **The mandatory 7-state machine.** Kept as an opt-in skill; the original ran it
  for every prompt including trivial ones.
- **"Small-model discipline"** (one action per turn, anchor the task id, never
  read >200 lines). Every rule maps to a real sub-frontier failure mode and costs
  a capable model parallelism for nothing.
- **`wf-run.sh`, task graphs, transcript corpora, retro/proposals.** Tier-B
  machinery for unattended local-model runs. They live in `ai-harness`.

## Self-test

```bash
./.claude/verify.sh     # 108 checks
```

Covers hook behavior (deny/ask/allow, block/pass/cap, edit-triggering, marker
lifecycle), verifier detection and the INERT path, Helm templates correctly
excluded from YAML parsing, both escape hatches, and that `install.sh --dry-run`
writes nothing.
