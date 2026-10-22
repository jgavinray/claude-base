#!/usr/bin/env python3
"""Ask the Jev service the stop-check question for every eval item.

  python3 -I score.py --variant v1 --split train --out OUT.jsonl [--jobs 2]

Goes through `hooks/stop-check.sh score` so the eval uses the exact masking, state
text and request the hook uses. The service averages the two option orders itself
(JEV_ORDERS=2). Resumes: ids already in OUT are skipped.
"""
import argparse, json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "../../hooks/stop-check.sh")
ITEMS = os.path.expanduser("~/dev/jev-evals/data/stop-check/items.jsonl")


def ask(it, qfile):
    env = dict(os.environ)
    if qfile:
        env["STOP_CHECK_QUESTION_FILE"] = qfile
    env["STOP_CHECK_TIMEOUT"] = "60"
    t = time.time()
    r = subprocess.run(["bash", HOOK, "score"], input=json.dumps({"assistant": it["assistant"], "user": it["user"]}).encode(),
                       capture_output=True, env=env)
    dt = time.time() - t
    try:
        probs = json.loads(r.stdout)["answers"]["stop"]["probabilities"]
    except Exception:
        probs = None
    return {"id": it["id"], "probs": probs, "seconds": round(dt, 3)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="embedded")
    ap.add_argument("--split", choices=["train", "test", "all"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    qfile = None if a.variant == "embedded" else os.path.join(HERE, "questions", a.variant + ".json")
    items = [json.loads(l) for l in open(ITEMS)]
    items = [i for i in items if a.split == "all" or i["split"] == a.split]
    done = set()
    if os.path.exists(a.out):
        done = {json.loads(l)["id"] for l in open(a.out) if l.strip()}
    todo = [i for i in items if i["id"] not in done]
    print("%d items, %d to do" % (len(items), len(todo)), file=sys.stderr)
    with open(a.out, "a") as f, ThreadPoolExecutor(a.jobs) as ex:
        for n, res in enumerate(ex.map(lambda i: ask(i, qfile), todo)):
            f.write(json.dumps(res, sort_keys=True) + "\n")
            f.flush()
            if n % 50 == 49:
                print("  %d done" % (n + 1), file=sys.stderr)


if __name__ == "__main__":
    main()
