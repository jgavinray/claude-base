---
name: workflow
description: Opt-in per-task state machine with gate-failure feedback routing. Use for multi-step work - a feature, a migration, a refactor spanning several files - when you want each stage gated rather than done in one pass. Not for single-file edits or questions.
---

# workflow

**This is opt-in.** Invoke it when work is genuinely multi-step. A one-file fix
or a question does not need a state machine, and running one costs more than it
returns.

You are the orchestrator: delegate each state to its subagent via the **Agent**
tool, execute IMPLEMENT and COMMIT yourself, and route feedback per the table.

## State file
`.claude/wf-state.json` — rewrite the WHOLE file at every transition:

```json
{
  "task": "T3",
  "state": "IMPLEMENT",
  "attempts": {"VERIFY": 1},
  "feedback": {"source": "verifier", "report": "VERDICT: FAIL\nFAILURES:\n- src/x.py: test_y: assertion"}
}
```

After a restart or compaction: read `wf-state.json` and `TASKS.md`, resume at the
recorded state. No state file means start at PLAN.

## States and gates

| State     | Who           | Gate to advance                  | PASS →    | FAIL → (carrying feedback)   |
|-----------|---------------|----------------------------------|-----------|------------------------------|
| PLAN      | planner       | TASKS.md written, items verifiable | IMPLEMENT | PLAN (refine using RISKS)  |
| IMPLEMENT | you           | code builds / imports cleanly    | TEST      | IMPLEMENT (compiler output)  |
| TEST      | qa-tester     | SUITE: PASS (FAILING_AS_INTENDED ok*) | VERIFY | IMPLEMENT (failing cases) |
| VERIFY    | verifier      | VERDICT: PASS                    | REVIEW    | IMPLEMENT (FAILURES + NEXT)  |
| REVIEW    | code-reviewer | VERDICT: APPROVE                 | DOCUMENT  | IMPLEMENT (ISSUES, HIGH first) |
| DOCUMENT  | doc-manager   | VERIFY: PASS after doc changes   | COMMIT    | DOCUMENT (its own failures)  |
| COMMIT    | you           | `git commit` succeeds            | next task | resolve git state, retry once |

\*FAILING_AS_INTENDED tests become new TASKS.md items; they do not block this task.

A VERIFY verdict of **INERT** is not a pass. It means the repo has no checks, so
the gate proved nothing — add checks or record honestly that the work is
unverified. Never let INERT advance to REVIEW silently.

## Feedback protocol
1. On gate failure, move to the fail-state and set `feedback` to the blocker's
   verbatim report, with `source` naming who produced it.
2. Address the FIRST feedback item only, then return directly to the gate that
   failed. Never skip forward, never re-plan mid-task.
3. Stop-gate blocks follow the same rule — treat the injected failure tail as
   feedback with source `stop-gate`.
4. Feedback is consumed, not accumulated: clear it once the gate passes.

## Escalation — never spin
- 3 consecutive failures of the SAME gate on the SAME task: mark it `BLOCKED:` in
  TASKS.md with the last feedback verbatim, clear wf-state, move to the next task.
- Identical error text twice: the approach is wrong. Change strategy before the
  third attempt — a different fix, not the same fix with more effort.
- All tasks BLOCKED: stop and report each with its final feedback. This is the
  only legitimate stop with red gates.

## Invariants
- Exactly one task in flight; `wf-state.json` names it.
- Gates are ordered — a later gate never runs while an earlier one is red.
- Only the gate defines pass/fail. Never self-assessment.
- Write every transition to disk before acting on it.

## Gate immutability
A single change may modify gate logic (verify.sh, checks.sh, the hooks) **or**
the behavior those gates judge — never both in one step. Nothing that benefits
from a looser gate may also be the thing that loosens it.
