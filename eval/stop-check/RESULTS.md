# stop-check results

Measured 10/21/2026. Wording v3 (embedded in the hook), threshold 0.65, Jev on hyper01 `:8102`.
Raw runs: `~/dev/jev-evals/data/stop-check/runs/` (kept on the owner's machine, masked).

## Ship rule

Do not ship if any owner-only stop is blocked on the test split, or if latency p95 is over 4 s.
Both held: 0 of 12 owner-only stops blocked, p95 1.8 s through the real hook.

## Test split (scored once, wording and threshold fixed on the training split)

459 items scored, 0 without an answer. 39 hand-backs, 380 negatives, 40 unlabelled (log turns ending in a question; reported, never in the rates).

| Measure | Result |
| --- | --- |
| AUC, hand-back vs everything else | 0.821 (95% bootstrap 0.762-0.874) |
| Block rate on hand-backs at 0.65 | 48.7% (19 of 39); 15 of 27 from the agent logs, 4 of 12 hand-labelled |
| False-block rate on all negatives | 13.2% (50 of 380) |
| Owner-only stops blocked | **0 of 12** (10 synthetic, 2 real) |
| Waiting on background work blocked | 2.0% (1 of 51) |
| Done / answered turns blocked | 0 of 10 done, 2 of 7 answered |

Latency:

| Path | n | p50 | p95 | max |
| --- | --- | --- | --- | --- |
| Whole hook, one stop at a time, random test items | 60 | 1.27 s | 1.81 s | 1.87 s |
| Eval path (2 parallel requests, includes masking) | 459 | 1.80 s | 2.48 s | 3.60 s |

The hook gives up at 4 s and allows the stop, so a slow or dead service never holds a stop.

## Reading the numbers

- It catches about half of the hand-backs and wrongly blocks about 1 in 8 of the other stops. The training split looked better (70% caught, 9.4% false blocks, AUC 0.904); the test split is the figure to trust.
- The false-block count is inflated by labels. Negatives include turns the owner did not complain about, but 73 of the 380 end in an explicit offer ("want me to", "say the word"), which is a hand-back under the owner's rules. Moving those out of the negatives (`analyze.py --audited`) gives AUC 0.861 and a false-block rate of 9.1% (28 of 307).
- Owner-only is the number that must not move. The highest score among the 12 was 0.556 (a real hand-labelled stop), under the 0.65 line. That margin is thin for one case, so the hook keeps two further limits: at most 2 blocks in a row, and the kill switch.
- Blocking costs one more turn from the agent, not a lost stop: after two blocks in a row the third stop is always allowed.

## Wording comparison (training split, threshold 0.65)

| Wording | AUC | Hand-backs blocked | Negatives blocked |
| --- | --- | --- | --- |
| v1 | 0.876 | 78.8% | 25.1% |
| v2 | 0.891 | 75.8% | 14.8% |
| v3 (chosen) | 0.904 | 69.7% | 9.4% |

## Not covered

- Labels come from the owner's own corrections in the agent logs plus hand labels from one session; no other owner or repo.
- 10 of the 12 owner-only test stops are synthetic. Real owner-only stops are rare in the logs (2).
- Message text is truncated to the last 2000 characters of the agent message and the first 400 of the message it answers; longer context is not judged.
- The eval measures the service's score, not what a live agent does after a block.
