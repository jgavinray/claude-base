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

`.claude/verify.sh` exits 0 or it doesn't. The model can't declare victory, and
it can't talk its way past a red check. Everything else here supports that. (The
automatic `Stop`-hook gate that used to enforce it was retired on 10/20/2026; the
verifier, the guard and the per-edit checks remain.)

The corollary matters just as much: **a gate that isn't armed must say so.** A
verifier that runs no checks and exits 0 is worse than no verifier, because it
reports green. `verify.sh --list` and the SessionStart hook both name that state
explicitly (`GATE INERT`), and the `verifier` agent reports `INERT` rather than
`PASS`.

## Layout

```
CLAUDE.md            global rules (at most 60 lines) -> ~/.claude/CLAUDE.md
settings.json        hook wiring + permissions.deny, merged into ~/.claude/settings.json
hooks/
  session-context.sh SessionStart: branch, dirty files, and whether the gate has teeth
  pretool-guard.sh   PreToolUse(Bash): two-tier deny/ask on destructive commands
  jev-shadow.sh      secret masking plus the background shadow call to the Jev service
  scope-check.sh     called by the guard: signals to processes the session did not start, hyper03, and a log-only Jev check
  post-edit-check.sh PostToolUse(Edit|Write): instant syntax check
verify/verify.sh     the auto-detecting verifier -> <repo>/.claude/verify.sh
agents/              qa-tester, verifier, code-reviewer, doc-manager
templates/           project CLAUDE.md skeleton
tests/base-test.sh   206 checks; claude-base gates itself with its own contract
install.sh           install the global layer
uninstall.sh         remove exactly what install.sh added
init-repo.sh         arm one repository (baselines what already fails)
LICENSE              GNU GPL v2
```

Per repo, `init-repo.sh` writes `.claude/verify.sh` and optionally
`.claude/baseline`. You add `.claude/checks.sh` when detection isn't enough.

## Install

```bash
./install.sh --dry-run     # see what it would do
./install.sh               # ~/.claude/{hooks,agents,skills,CLAUDE.md} + settings merge
./init-repo.sh ~/dev/some-repo
```

`install.sh` backs up `settings.json` before merging, replaces only the four hook
events it owns, unions `permissions.deny`, and sets `attribution` to empty so
commits and PRs carry no generated-by trailer. Re-running is idempotent.

**Repos that carry their own harness are left alone.** Hooks from `~/.claude`
and `<repo>/.claude` *merge* — both sets run — so a project with its own
`SessionStart` hook would otherwise print two context blocks. The global hooks detect a
project-level registration for the same event and step aside, per event.

**Global, not per-repo** — the inverse of the original harness's recommendation.
With one machine and 100+ repos, copying four scripts into each one guarantees
drift. The tradeoff is real: a fresh clone elsewhere is unguarded, and repo
scanners can't see hooks in `$HOME`. If a specific repo needs to carry its own
harness, copy `hooks/` into it and switch the paths back to `$CLAUDE_PROJECT_DIR`.

Requires `jq`. Verify wiring with `/hooks` inside Claude Code.
`./uninstall.sh` removes exactly what was added and leaves everything else in
`settings.json` alone.

**Cloning a repo requires no setup.** Global hooks apply everywhere
automatically, and a repo with no `.claude/verify.sh` simply has no gate — the
guard and per-edit syntax checks stay active, and
SessionStart reports `GATE ABSENT` so a green result is never implied. There is
no preflight. `init-repo.sh` is how you opt a repo *in*, when you want one.

## Jev shadow call

Since 10/20/2026 the guard also sends each shell command to a local Jev-style
decision service (`jev/` in `jgavinray/mission-control`, on hyper01 port 8102,
backed by GLM). It asks "what is the risk of this command?" (read, edit, push,
deploy, destroy) and the service logs the answer so it can be spot-checked
later. Nothing acts on the answer yet.

- **Shadow only.** The call runs in the background, nothing waits for it, and
  it never changes a deny, ask or allow. If the service is down or slow, the
  hook behaves the same. The call adds under 20 ms (tested; measured about 2 ms).
- **Secrets are masked on this machine first** (`jev-shadow.sh redact`):
  `ghp_`/`gho_`/..., `github_pat_`, `hf_`, `sk-`, `AKIA`, `xox*`, `Bearer`/`Basic`/`Token`
  values, `password=`/`token=`/`secret=`/`api_key=` values, PEM blocks, URL
  passwords, and hex or base64-looking runs over 32 characters. The command
  travels on stdin, never on a command line.
- **Kill switch:** `touch ~/.claude/jev-shadow-off` stops it at once (the guard
  checks the file on every command); `rm ~/.claude/jev-shadow-off` turns it back on.
- Settings: `JEV_SHADOW_URL` (default `http://192.168.0.44:8102`),
  `JEV_SHADOW_TIMEOUT` seconds (default 8).
- `install.sh` copies `jev-shadow.sh` with the other hooks.

## Scope check

`scope-check.sh` (called by `pretool-guard.sh` for commands the guard allows)
asks "does this touch work the agent did not start?". Since 10/21/2026:

- **Enforced, no model:** `kill`/`pkill`/`killall` (also `-STOP`) deny unless the
  target is a process this session started (a child of the session, started from
  its scratchpad, or in a pid file in its scratchpad); a name or path pattern is
  expanded with `pgrep` first. NVIDIA, driver and reboot commands aimed at
  hyper03 (192.168.0.43) deny.
- **Logged only:** service control, overwrites outside the workspace, ssh state
  changes and other hyper03 use are sent to Jev in the background
  (`model: jev-scope-check`) and the answer goes to `~/.claude/scope-check.log`.
  Nothing waits for it. `touch ~/.claude/scope-check-jev-enforce` makes it decide.
- **Kill switch:** `touch ~/.claude/scope-check-off`.
- Doc: `wiki/scope-check.md` in the memory store.

## Reproducibility

Detection is environment-dependent by design — a check registers only if its
tool is installed. That means the same repo can gate differently on two machines
while both report green. Three things address it:

- **`init-repo.sh --pin`** writes `.claude/expected-checks`. After that, a
  missing tool is a hard **failure** rather than a silent smaller gate:
  "ruff is not installed" should look like a broken setup, not a passing build.
- **`templates/ci.yml`** runs the same `.claude/verify.sh` in GitHub Actions, so
  local and CI can't drift into two different definitions of done.
- **Per-check timeouts** (`CLAUDE_BASE_CHECK_TIMEOUT`, default 300s) make a hung
  check fail and name itself, and `LC_ALL=C` pins collation.

File lists come from `git ls-files | sort` — never `grep -r` recursion order,
and never truncated. An earlier version capped the kubeconform list at 500
files, which silently validated an arbitrary subset of a larger repo.

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

Checks stop at the first *new* failure, so the model fixes one thing at a time.
Use `--list` to see what would run, and `--audit` to run everything and report
every failure without blocking.

A check is only registered when its tool is actually installed. If nothing is
installed, the repo reports INERT rather than running a check that silently
no-ops — a gate that skips is indistinguishable from a gate that passes, and
that's the failure this whole design exists to prevent.

## Arming a repo that is already red

`init-repo.sh` runs the detected checks *before* arming and tells you where you
stand:

```
GATE ARMED — currently RED, baseline recorded.
  Pre-existing failures (2), written to .claude/baseline:
    - cargo-clippy
    - ruff-check
```

Those are recorded in `.claude/baseline` and reported but **do not block** —
they came with the codebase. Anything you break beyond them does. So the gate
means *no regression from a recorded starting point*, with absolute green as the
special case of an empty baseline.

This matters because arming a red gate is worse than no gate: `cargo clippy
-- -D warnings` on an inherited codebase fails on day one, blocks every session
over debt you didn't create, and teaches you to ignore the gate. A check that
starts passing gets flagged for removal from the baseline, so a stale entry
can't hide a real regression later.

It's also what makes this safe on a **fork you contribute back to**. Upstream's
existing failures are recorded; yours are not. Refusing to arm forks would be
backwards — a change you intend to send upstream needs the gate more than
average, not less. Use `--local` to keep `.claude/` in `.git/info/exclude` so
the harness never shows up in a pull request; it's suggested automatically when
an `upstream` remote exists.

## One thing that differs from the original harness

**The guard has two tiers.** DENY for the unrecoverable (namespace deletion,
`terraform destroy`, `helm uninstall`, PV/PVC deletion, force-push without
`--force-with-lease`, cloud resource deletion). ASK for the destructive-but-useful
(`kubectl delete <resource>`, `terraform apply`, `git reset --hard`, publishes).
The original blocked `rm -rf /` and nothing that touches a cluster.

Recursive delete is the exception: it uses an **allowlist**, because a denylist
cannot work there. `rm -rf /` is the case that never happens; `rm -rf ./src` and
`rm -rf ~/dev/<project>` are the ones that do, and no pattern distinguishes the
latter from legitimate cleanup. So known-ephemeral paths (build output, caches,
vendored deps) pass silently, unrecoverable targets are denied, and everything
else asks.

Everything else is a denylist over command text, so it is a **floor, not a
fence** — obfuscation, shell variables, and scripts-calling-scripts defeat it by
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
./.claude/verify.sh     # 136 checks
```

Covers hook behavior (deny/ask/allow, block/pass/cap, edit-triggering, marker
lifecycle), recursive-delete allowlist semantics, verifier detection and the
INERT path, baseline gating (pre-existing vs new failures, stale entries),
project-harness deferral, file discovery including untracked files while
excluding `.claude/` itself, Helm templates correctly excluded from YAML
parsing, both escape hatches, and that `install.sh --dry-run` writes nothing.

## License

Copyright (C) 2026 J. Gavin Ray

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.
