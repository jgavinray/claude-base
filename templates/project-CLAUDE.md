# <project>

<!-- Keep this under ~40 lines. Long instruction files get skimmed, not followed. -->
<!-- Global rules live in ~/.claude/CLAUDE.md — do not repeat them here. -->

## What this is
<one or two sentences: what it does, who consumes it, what breaking it costs>

## Stack
- Language/toolchain: <pinned version>
- Build: `<command>`
- Test: `<command>`
- Lint/format: `<command>`

## Definition of done
`.claude/verify.sh` exits 0.
<If the auto-detected checks are not sufficient, add real ones to .claude/checks.sh>

## Conventions
- <error handling style, module layout, naming>
- <directories that are generated and must never be hand-edited>

## Never run here
- <e.g. terraform apply, kubectl delete against prod, migrations>
- <e.g. anything that touches the live cluster from a laptop>

## Where truth lives
- <docs/, ADRs, the runbook — where a claim about behavior should be checked>
