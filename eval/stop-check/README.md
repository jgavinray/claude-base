# stop-check eval

Offline proof for `hooks/stop-check.sh`, run on the owner's own data before the hook
went live. The data stays on the owner's machine (`~/dev/jev-evals/data/stop-check/`,
masked); this directory holds only the code and the question wordings.

| File | What it does |
| --- | --- |
| `build_eval.py` | Builds `items.jsonl` from the agent-log labels (v2 units, judge verdicts), hand labels from the 10/20-10/21 main session, and 16 synthetic owner-only stops. Masks every text with `hooks/jev-shadow.sh redact`. |
| `questions/v1.json` `v2.json` `v3.json` | The three wordings tried on the training split. `selected.json` is the one embedded in the hook (a test checks they match). |
| `score.py` | Sends every item through `hooks/stop-check.sh score`, so the eval uses the hook's own masking, state text and request. The service averages 2 option orders. |
| `analyze.py` | AUC (bootstrap interval), block rate on positives, false-block rate on negatives, the subsets, latency, and `--pick` for the threshold. |
| `mutation-proof.sh` | Breaks the hook nine ways and requires the gate's stop-check tests to fail on each. |
| `RESULTS.md` | The numbers. |

Run order: `python3 -I build_eval.py`, then `score.py --variant vN --split train --out RUN`, then
`analyze.py RUN --split train --pick`. The test split is scored once, with the chosen wording and threshold.

## Labels

- Positive (handing_back): an agent turn that ended, right before an owner correction whose failure mode is
  `stopping_short` or `excessive_questions` (judge verdict if there is one, else the labellers), plus 22 turns
  hand-labelled from the main session transcript (10/20-10/21). 8 of the 58 log candidates were dropped after reading
  them (build_eval.py lists which and why).
- Negative: an agent turn that ended where the next owner message is a new instruction, a question, an approval or
  information, with no failure mode. Log turns that end in a `?` are kept apart (`ambiguous`, never scored as
  negatives: an owner answering "yes" to a question is exactly the excessive-question case).
- `waiting_on_background`: 41 turns hand-labelled from the main session, plus log turns whose last lines match a
  "still running / will report" pattern.
- `owner_only`: 2 real turns plus 16 synthetic stops written for this eval (a stop that asks the owner to confirm a
  destructive step on work the agent does not own is legitimate). Synthetic cases are reported on their own.
- Train/test split: by hash of the session for the logs (no session on both sides); alternating by item for the one
  hand-labelled session and for the synthetic set.
