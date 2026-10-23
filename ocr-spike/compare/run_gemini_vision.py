#!/usr/bin/env python3
"""
Gemini vision OCR side of the comparison — BATCHED to fit the free-tier
window (multi-image requests: ~5 synthetic or ~4 real pages per request).

- only HTTP 200 accepted; 503/429/000 redialed up to 3 attempts (backoff)
- incremental save + resume: finished files are skipped on re-run
- budget guard: stops after MAX_REQUESTS requests (default 7) to leave
  quota for the gate/providers baseline
Usage: ./venv/bin/python run_gemini_vision.py [--max-requests N]
"""
import base64
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")
KEY = None
for line in open(os.path.join(HERE, "..", "..", "translation-spike", ".env")):
    if line.startswith("GEMINI_API_KEY="):
        KEY = line.split("=", 1)[1].strip().strip('"').strip("'")
if not KEY:
    sys.exit("GEMINI_API_KEY not found")

MODEL = "gemini-3.8-flash"
URL = (f"https://generativelanguage.googleapis.com/v1beta/models/"
       f"{MODEL}:generateContent?key={KEY}")
PROMPT = (
    "You are doing OCR of comic pages. For EACH image below (numbered in "
    "order), transcribe ALL visible text EXACTLY as written: same language, "
    "same capitalization, same punctuation, preserve all diacritics. "
    "Do not translate. Do not add commentary or labels. If an image has no "
    "text, use an empty string. Put each separate text block/line on its own "
    "line, joined with \\n.\n"
    'Return ONLY a JSON array: [{"i": 1, "text": "..."}, ...] with one '
    "entry per image, in order."
)
MAX_REQ = 7


def post(payload, attempts=3):
    for a in range(1, attempts + 1):
        req = urllib.request.Request(
            URL, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                body = json.load(r)
            return body, int((time.time() - t0) * 1000), None
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:200]
            if e.code in (429, 503) and a < attempts:
                wait = a * 6
                print(f"    HTTP {e.code} — retry in {wait}s "
                      f"(attempt {a}/{attempts})")
                time.sleep(wait)
                continue
            return None, int((time.time() - t0) * 1000), f"HTTP {e.code}: {detail}"
        except Exception as e:  # 000 / timeout
            if a < attempts:
                wait = a * 6
                print(f"    {e} — retry in {wait}s (attempt {a}/{attempts})")
                time.sleep(wait)
                continue
            return None, int((time.time() - t0) * 1000), f"network: {e}"
    return None, 0, "exhausted attempts"


def parse_array(text):
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`")
        s = s[s.find("["):]
    try:
        return json.loads(s)
    except Exception:
        i, j = s.find("["), s.rfind("]")
        if i >= 0 and j > i:
            return json.loads(s[i:j + 1])
        raise


def run_track(name, files, out_path, batch_size, used):
    done = {}
    if os.path.exists(out_path):
        done = {r["file"]: r for r in json.load(open(out_path))}
    todo = [f for f in files if os.path.basename(f) not in done]
    print(f"[{name}] {len(files)} files, {len(todo)} todo, "
          f"request budget left: {MAX_REQ - used}")

    batches = [todo[i:i + batch_size] for i in range(0, len(todo), batch_size)]
    for bi, batch in enumerate(batches):
        if used >= MAX_REQ:
            print(f"  budget guard: stopping before batch {bi+1} "
                  f"(resume by re-running)")
            break
        parts = [{"text": PROMPT}]
        for i, f in enumerate(batch, 1):
            parts.append({"text": f"Image {i} of {len(batch)}:"})
            b64 = base64.b64encode(open(f, "rb").read()).decode()
            parts.append({"inline_data": {"mime_type": "image/png",
                                          "data": b64}})
        payload = {"contents": [{"parts": parts}],
                   "generationConfig": {"responseMimeType": "application/json",
                                        "temperature": 0,
                                        # thinking was the latency culprit:
                                        # 5-image batch took 110s with
                                        # default thinking, 6s without (probe)
                                        "thinkingConfig": {"thinkingBudget": 0}}}
        body, ms, err = post(payload)
        used += 1
        if err:
            print(f"  batch {bi+1} FAILED after redials: {err}")
            break
        try:
            cand = body["candidates"][0]
            arr = parse_array(cand["content"]["parts"][0]["text"])
        except Exception as e:
            print(f"  batch {bi+1} unparseable ({e}): "
                  f"{str(body)[:300]}")
            break
        um = body.get("usageMetadata", {})
        print(f"  batch {bi+1}: {len(batch)} imgs, {ms}ms, "
              f"tokens in/out {um.get('promptTokenCount')}/"
              f"{um.get('candidatesTokenCount')}")
        for i, f in enumerate(batch, 1):
            entry = next((x for x in arr if x.get("i") == i), None)
            done[os.path.basename(f)] = dict(
                file=os.path.basename(f), path=f, text=(entry or {}).get(
                    "text", "" if entry else "PARSE_MISS"),
                model=MODEL, ms=ms // len(batch), batch=bi + 1,
                prompt_tokens=um.get("promptTokenCount"),
                output_tokens=um.get("candidatesTokenCount"))
        json.dump(list(done.values()), open(out_path, "w"),
                  ensure_ascii=False, indent=1)
    return used


def main():
    global MAX_REQ
    if "--max-requests" in sys.argv:
        MAX_REQ = int(sys.argv[sys.argv.index("--max-requests") + 1])
    os.makedirs(RES, exist_ok=True)
    used = 0

    manifest = json.load(open(os.path.join(HERE, "manifest.json")))
    synth = [os.path.join(HERE, m["file"]) for m in manifest]
    real = sorted(glob.glob(os.path.join(HERE, "..", "images",
                                          "fog60_*.png")))

    used = run_track("synthetic", synth,
                     os.path.join(RES, "gemini_synth.json"), 5, used)
    used = run_track("real", real,
                     os.path.join(RES, "gemini_real.json"), 4, used)
    print(f"total requests used: {used}/{MAX_REQ}")


if __name__ == "__main__":
    main()
