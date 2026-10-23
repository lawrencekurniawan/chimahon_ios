#!/usr/bin/env python3
"""
Scores OCR engines for the comprehensive comparison (2026-10-22):

- Synthetic track: character error rate (CER) vs KNOWN ground truth
  (manifest.json), per style, plus exact-match and Vision confidence.
- Real-page track: engine-to-engine text diff (no ground truth) →
  disagreements listed for human/pixel adjudication.

Usage: ./venv/bin/python score.py
Outputs: results/comparison.json + markdown tables on stdout.
"""
import glob
import json
import os
import re
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")


def flow(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", s)).strip()


def lines_norm(s):
    out = []
    for ln in unicodedata.normalize("NFC", s).splitlines():
        ln = re.sub(r"[ \t]+", " ", ln).strip()
        if ln:
            out.append(ln)
    return out


def lev(a, b):
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1,
                           prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(gt, hyp):
    g, h = flow(gt), flow(hyp)
    if not g:
        return 0.0 if not h else 1.0
    return lev(g, h) / len(g)


def load_results(pattern):
    """Returns {basename: text}, {basename: extra-dict}."""
    texts, extra = {}, {}
    for f in sorted(glob.glob(os.path.join(RES, pattern))):
        for rec in json.load(open(f)):
            if "error" in rec:
                texts[rec["file"]] = ""
                extra[rec["file"]] = {"error": rec["error"]}
                continue
            if "lines" in rec:  # Vision shape
                texts[rec["file"]] = "\n".join(l["text"] for l in rec["lines"])
                if rec["lines"]:
                    extra[rec["file"]] = {
                        "ms": rec.get("ms"),
                        "mean_conf": sum(l["confidence"] for l in rec["lines"])
                        / len(rec["lines"]),
                        "min_conf": min(l["confidence"] for l in rec["lines"]),
                    }
                else:
                    extra[rec["file"]] = {"ms": rec.get("ms"),
                                          "mean_conf": None, "min_conf": None}
            else:  # Gemini shape: {file, text, ms, model, ...}
                texts[rec["file"]] = rec.get("text", "")
                extra[rec["file"]] = {"ms": rec.get("ms"),
                                      "model": rec.get("model")}
    return texts, extra


def main():
    manifest = json.load(open(os.path.join(HERE, "manifest.json")))

    engines = {
        "apple-vision": load_results("vision_*.json"),
        "gemini-vision": load_results("gemini_*.json"),
    }
    engines = {k: v for k, v in engines.items() if v[0]}

    print("# Synthetic track (ground truth, CER)\n")
    per_engine = {}
    for ename, (texts, extra) in engines.items():
        rows, edits, chars, exacts = [], 0, 0, 0
        for m in manifest:
            base = os.path.basename(m["file"])
            gt, hyp = m["text"], texts.get(base, None)
            if hyp is None:
                continue
            c_flow = cer(gt, hyp)
            c_lines = lev("\n".join(lines_norm(gt)),
                          "\n".join(lines_norm(hyp))) / max(
                1, len("\n".join(lines_norm(gt))))
            g = flow(gt)
            edits += lev(g, flow(hyp))
            chars += len(g)
            ex = flow(gt) == flow(hyp)
            exacts += ex
            rows.append(dict(id=m["id"], style=m["style"], cer_flow=c_flow,
                             cer_lines=c_lines, exact=ex, hyp=hyp,
                             conf=extra.get(base, {}).get("mean_conf"),
                             ms=extra.get(base, {}).get("ms")))
        per_engine[ename] = dict(rows=rows, edits=edits, chars=chars,
                                 exacts=exacts,
                                 n=sum(1 for m in manifest
                                       if os.path.basename(m["file"]) in texts))
        n = per_engine[ename]["n"]
        print(f"## {ename}: {exacts}/{n} exact, "
              f"weighted CER {edits/max(1,chars)*100:.2f}%")
        for r in sorted(rows, key=lambda r: -r["cer_flow"]):
            if not r["exact"]:
                print(f"  CER {r['cer_flow']*100:5.1f}%  {r['id']:24} "
                      f"[{r['style']}]")
                print(f"      GT : {flow(manifest[[m['id'] for m in manifest].index(r['id'])]['text'])!r}")
                print(f"      GOT: {flow(r['hyp'])!r}")
        print()

    # Vision confidence calibration: does low conf predict error?
    if "apple-vision" in per_engine:
        print("## apple-vision confidence vs correctness")
        for r in per_engine["apple-vision"]["rows"]:
            if not r["exact"] or (r["conf"] is not None and r["conf"] < 0.99):
                print(f"  {r['id']:24} exact={r['exact']} "
                      f"conf={r['conf']} ms={r['ms']}")
        ms = [r["ms"] for r in per_engine["apple-vision"]["rows"]
              if r["ms"] and r["ms"] < 1000]
        if ms:
            print(f"  latency mean {sum(ms)/len(ms):.0f}ms "
                  f"(excl. warmup) over {len(ms)} pages\n")

    # ---------------- real pages: engine diff (adjudication queue) ----------------
    real = {}
    for ename, (texts, extra) in engines.items():
        for f, t in texts.items():
            if f.startswith("fog60_"):
                real.setdefault(f, {})[ename] = t
    print("# Real pages track (disagreements → adjudication)\n")
    disagree = []
    for f in sorted(real):
        ens = real[f]
        vals = {e: flow(t) for e, t in ens.items()}
        if len(set(vals.values())) > 1:
            disagree.append(f)
            print(f"DISAGREE {f}")
            for e, t in vals.items():
                print(f"  {e:14}: {t[:300]!r}")
        else:
            same = next(iter(vals.values()))
            tag = "both-empty" if not same else "both-agree"
            print(f"OK {f:18} {tag} ({len(same)} chars)")
    print(f"\n{len(disagree)} disagreement(s): {disagree}")

    json.dump(dict(
        engines={k: dict(exact=v["exacts"], n=v["n"],
                         weighted_cer=v["edits"] / max(1, v["chars"]),
                         rows=v["rows"])
                 for k, v in per_engine.items()},
        disagreements=disagree,
    ), open(os.path.join(RES, "comparison.json"), "w"),
        ensure_ascii=False, indent=1)
    print("\nwrote results/comparison.json")


if __name__ == "__main__":
    main()
