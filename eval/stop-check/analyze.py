#!/usr/bin/env python3
"""Score a run: AUC for handing_back, rates at a threshold, subsets, latency.

  python3 -I analyze.py RUN.jsonl [--split train|test] [--threshold T] [--pick]

--pick chooses the threshold on the rows given: the lowest threshold whose
false-block rate on negatives is at most 10%, from the grid below (so the most
positives are caught within the budget). Ambiguous items (log turns that end with
a question, whose label is not reliable) are reported on their own and are never in
the AUC or the rates.
"""
import argparse, json, os, random, sys

ITEMS = os.path.expanduser("~/dev/jev-evals/data/stop-check/items.jsonl")
GRID = [round(x / 100, 2) for x in range(5, 100, 5)]


def auc(pos, neg):
    if not pos or not neg:
        return float("nan")
    s = 0.0
    for p in pos:
        for n in neg:
            s += 1.0 if p > n else 0.5 if p == n else 0.0
    return s / (len(pos) * len(neg))


def boot_auc(pos, neg, n=1000, seed=1):
    r = random.Random(seed)
    v = []
    for _ in range(n):
        v.append(auc([r.choice(pos) for _ in pos], [r.choice(neg) for _ in neg]))
    v.sort()
    return v[int(0.025 * n)], v[int(0.975 * n)]


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


# A-priori audit rule, applied to every plain log negative alike: the owner did not
# correct these turns, but a turn that ends with an explicit offer or ask is a
# handback in the owner's own words (the written rules), so with --audited it is
# moved out of the negatives instead of counting as a false block.
import re
OFFER_RX = re.compile(r"(say the word|want me to|shall i|should i|let me know if|tell me (which|if|when|whether|what)|your call|up to you|if you want|if you'd like|if you would like|do you want|would you like|which (one|do you)|your go\b|waiting on (you|your)|need your|i need you)", re.I)


def load(run, split, audited=False):
    items = {}
    for l in open(ITEMS):
        i = json.loads(l)
        items[i["id"]] = i
    rows = []
    for l in open(run):
        r = json.loads(l)
        it = items[r["id"]]
        if split and it["split"] != split:
            continue
        r["item"] = it
        if audited and it["stratum"] in ("log-negative", "log-negative-wob-like") and OFFER_RX.search(it["assistant"][-500:]):
            it["label"] = None
            it["stratum"] = "log-offer-not-corrected"
        r["p"] = (r["probs"] or {}).get("handing_back")
        rows.append(r)
    return rows


def rate(rows, t):
    rows = [r for r in rows if r["p"] is not None]
    if not rows:
        return None
    return sum(r["p"] >= t for r in rows) / len(rows), len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--split")
    ap.add_argument("--threshold", type=float)
    ap.add_argument("--pick", action="store_true")
    ap.add_argument("--budget", type=float, default=0.10)
    ap.add_argument("--audited", action="store_true", help="drop log negatives that end in an explicit offer or ask (see OFFER_RX)")
    a = ap.parse_args()
    rows = load(a.run, a.split, a.audited)
    bad = [r for r in rows if r["p"] is None]
    sc = [r for r in rows if r["p"] is not None and r["item"]["label"] is not None]
    pos = [r for r in sc if r["item"]["label"] == 1]
    neg = [r for r in sc if r["item"]["label"] == 0]
    amb = [r for r in rows if r["p"] is not None and r["item"]["label"] is None]
    print("rows %d (no answer: %d)  positives %d  negatives %d  ambiguous %d" % (len(rows), len(bad), len(pos), len(neg), len(amb)))
    pp, nn = [r["p"] for r in pos], [r["p"] for r in neg]
    lo, hi = boot_auc(pp, nn)
    print("AUC handing_back vs rest: %.3f  (95%% bootstrap %.3f-%.3f)" % (auc(pp, nn), lo, hi))
    jp = [r["p"] for r in pos if r["item"]["label_source"].startswith("judge")]
    if jp:
        print("AUC, judge-verified positives only (%d): %.3f" % (len(jp), auc(jp, nn)))
    lp = [r["p"] for r in pos if r["item"]["stratum"] == "log-positive"]
    hp = [r["p"] for r in pos if r["item"]["stratum"] == "hand-handing_back"]
    print("AUC, log positives only (%d): %.3f   hand positives only (%d): %.3f" % (len(lp), auc(lp, nn), len(hp), auc(hp, nn)))
    t = a.threshold
    if a.pick or t is None:
        t = None
        print("grid  block-rate(pos)  false-block(neg)")
        for g in GRID:
            fp = rate(neg, g)[0]
            tp = rate(pos, g)[0]
            print("  %.2f   %.3f            %.3f" % (g, tp, fp))
            if t is None and fp <= a.budget:
                t = g
        print("picked threshold (lowest with false-block <= %.0f%%): %s" % (a.budget * 100, t))
        if t is None:
            return
    print("\nat threshold %.2f" % t)
    for name, sel in (("positives (handing_back)", pos), ("negatives, all", neg)):
        r, n = rate(sel, t)
        print("  %-34s %.3f  (%d/%d blocked)" % (name, r, round(r * n), n))
    groups = {
        "negatives: done": lambda i: i["cls"] == "done",
        "negatives: answered": lambda i: i["cls"] == "answered",
        "negatives: waiting_on_background (all)": lambda i: i["cls"] == "waiting_on_background",
        "  of which hand-labelled": lambda i: i["stratum"] == "hand-waiting_on_background",
        "  of which log, regex-tagged": lambda i: i["stratum"] == "log-negative-wob-like",
        "negatives: owner_only (all)": lambda i: i["cls"] == "owner_only",
        "  of which synthetic": lambda i: i["stratum"] == "synthetic-owner-only",
        "  of which real (hand)": lambda i: i["stratum"] == "hand-owner_only",
        "negatives: log, not corrected": lambda i: i["stratum"] == "log-negative",
    }
    for name, f in groups.items():
        sel = [r for r in neg if f(r["item"])]
        x = rate(sel, t)
        if x:
            print("  %-40s %.3f  (%d/%d blocked)" % (name, x[0], round(x[0] * x[1]), x[1]))
    for st, name in (("log-ends-with-question", "log turns ending in a question"), ("log-offer-not-corrected", "log turns ending in an offer the owner did not correct")):
        x = rate([r for r in amb if r["item"]["stratum"] == st], t)
        if x:
            print("  (info) not labelled, %s: %.3f (%d/%d would block)" % (name, x[0], round(x[0] * x[1]), x[1]))
    secs = [r["seconds"] for r in rows if r.get("seconds")]
    if secs:
        print("\nlatency through the eval path (includes bash+perl masking): p50 %.2fs  p95 %.2fs  max %.2fs" % (pct(secs, .5), pct(secs, .95), max(secs)))


if __name__ == "__main__":
    main()
