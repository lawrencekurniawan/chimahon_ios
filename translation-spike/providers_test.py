#!/usr/bin/env python3
"""Free-provider quality comparison harness (user decision 2026-10-22: Groq + Cohere).

Sends the SAME production contract payloads (requests/req_vi|ko|batch.json) to
each configured provider, validates the explain-schema contract, measures
latency/usage, and saves outputs side-by-side for quality review against the
Gemini baseline.

Stdlib only — no pip installs. Keys come from .env (gitignored):
  GEMINI_API_KEY, GROQ_API_KEY, COHERE_API_KEY

Usage:
  python3 providers_test.py                 # everything configured
  python3 providers_test.py --providers groq,cohere
  python3 providers_test.py --payloads vi    # single payload
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
RESULTS = HERE / "results"
PAYLOADS = ["vi", "ko", "batch"]

# (provider, model) matrix — models verified against provider docs 2026-10-22
MATRIX = {
    "gemini": [("gemini-3.8-flash", True)],  # True = native JSON schema mode available
    "groq": [("qwen/qwen3.8-27b", True), ("openai/gpt-oss-120b", True)],
    "cohere": [
        ("command-a-translate-08-2025", False),  # MT specialist (ko+vi), NOT in structured-outputs list
        ("c4ai-aya-expanse-32b", False),         # multilingual generalist (ko+vi), NOT in list
        ("command-a-03-2025", True),             # flagship, structured outputs supported
    ],
}


def load_env():
    env_file = HERE / ".env"
    env = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def extract_prompt(payload: str) -> str:
    req = json.loads((HERE / "requests" / f"req_{payload}.json").read_text())
    return req["contents"][0]["parts"][0]["text"]


def post(url: str, headers: dict, payload: dict, timeout: int = 90):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode()), time.time() - t0
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(body), time.time() - t0
        except Exception:
            return e.code, {"raw": body[:800]}, time.time() - t0
    except Exception as e:  # network / timeout
        return 0, {"error": str(e)}, time.time() - t0


def http_error_message(resp) -> str:
    if isinstance(resp, dict):
        if "error" in resp and isinstance(resp["error"], dict):
            return str(resp["error"].get("message", ""))[:300]
        if "message" in resp:
            return str(resp["message"])[:300]
        if "raw" in resp:
            return str(resp["raw"])[:300]
        if "error" in resp:
            return str(resp["error"])[:300]
    return ""


# ---------------------------------------------------------------- adapters

def call_gemini(key, model, payload):
    req_path = HERE / "requests" / f"req_{payload}.json"
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{model}:generateContent?key={key}")
    status, resp, dt = post(url, {}, json.loads(req_path.read_text()))
    text, usage = None, {}
    if status == 200:
        try:
            text = resp["candidates"][0]["content"]["parts"][0]["text"]
            um = resp.get("usageMetadata", {})
            usage = {"prompt": um.get("promptTokenCount"), "completion": um.get("candidatesTokenCount"),
                     "model_version": resp.get("modelVersion")}
        except Exception:
            pass
    return status, text, usage, dt, http_error_message(resp)


def call_openai_compat(base_url, key, model, prompt, json_mode):
    """Groq (and any OpenAI-compatible endpoint)."""
    payload = {"model": model, "messages": [{"role": "user", "content": prompt}]}
    if json_mode:
        payload["response_format"] = {"type": "json_object"}
    status, resp, dt = post(f"{base_url}/chat/completions", {"Authorization": f"Bearer {key}"}, payload)
    err = http_error_message(resp)
    if status == 400 and json_mode and "response_format" in err.lower():
        # model/endpoint doesn't accept JSON mode — retry prompt-only
        payload.pop("response_format")
        status, resp, dt = post(f"{base_url}/chat/completions",
                                {"Authorization": f"Bearer {key}"}, payload)
        err = http_error_message(resp)
        json_mode = False
    text, usage = None, {}
    if status == 200:
        try:
            text = resp["choices"][0]["message"]["content"]
            u = resp.get("usage", {})
            usage = {"prompt": u.get("prompt_tokens"), "completion": u.get("completion_tokens")}
        except Exception:
            pass
    return status, text, usage, dt, err, json_mode


def call_cohere(key, model, prompt, json_mode):
    payload = {"model": model, "messages": [{"role": "user", "content": prompt}]}
    if json_mode:
        payload["response_format"] = {"type": "json_object"}
    status, resp, dt = post("https://api.cohere.com/v2/chat",
                            {"Authorization": f"Bearer {key}"}, payload)
    err = http_error_message(resp)
    if status >= 400 and json_mode and err:
        # model not in structured-outputs compatible list → prompt-only retry
        payload.pop("response_format")
        status, resp, dt = post("https://api.cohere.com/v2/chat",
                                {"Authorization": f"Bearer {key}"}, payload)
        err = http_error_message(resp)
        json_mode = False
    text, usage = None, {}
    if status == 200:
        try:
            text = resp["message"]["content"][0]["text"]
            u = resp.get("usage", {}) or {}
            usage = {"prompt": u.get("billed_units", {}).get("input_tokens"),
                     "completion": u.get("billed_units", {}).get("output_tokens")}
        except Exception:
            pass
    return status, text, usage, dt, err, json_mode


# ---------------------------------------------------------------- validation

def validate(payload: str, text):
    """Returns (ok, detail). Contract: FEASIBILITY §10 explain schema."""
    if text is None:
        return False, "no text"
    try:
        parsed = json.loads(text)
    except Exception as e:
        # tolerate markdown fences / leading prose
        s = text.strip()
        if s.startswith("```"):
            s = s.split("\n", 1)[1] if "\n" in s else s
            s = s.rsplit("```", 1)[0].strip()
        try:
            parsed = json.loads(s)
        except Exception:
            return False, f"invalid JSON ({e})"
    if payload == "batch":
        if not isinstance(parsed, list) or not parsed:
            return False, "expected non-empty array"
        missing = [i for i, it in enumerate(parsed)
                   if not (isinstance(it, dict) and "full_translation" in it)]
        if missing:
            return False, f"items missing full_translation: {missing}"
        return True, f"{len(parsed)} bubbles"
    if not isinstance(parsed, dict):
        return False, "expected object"
    if not parsed.get("full_translation"):
        return False, "missing full_translation"
    if not parsed.get("word_by_word"):
        return False, "missing word_by_word"
    return True, f"{len(parsed.get('word_by_word', []))} word entries"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--providers", default="gemini,groq,cohere")
    ap.add_argument("--payloads", default=",".join(PAYLOADS))
    args = ap.parse_args()

    env = load_env()
    providers = [p.strip() for p in args.providers.split(",") if p.strip()]
    payloads = [p.strip() for p in args.payloads.split(",") if p.strip()]
    RESULTS.mkdir(exist_ok=True)

    key_names = {"gemini": "GEMINI_API_KEY", "groq": "GROQ_API_KEY", "cohere": "COHERE_API_KEY"}
    rows, exit_bad = [], 0

    for provider in providers:
        key = env.get(key_names[provider], os.environ.get(key_names[provider], ""))
        if not key:
            print(f"⚠️  SKIP {provider}: {key_names[provider]} not in .env")
            continue
        for model, json_mode in MATRIX[provider]:
            for pl in payloads:
                prompt = extract_prompt(pl)
                if provider == "gemini":
                    status, text, usage, dt, err = call_gemini(key, model, pl)
                    used_json_mode = json_mode
                elif provider == "groq":
                    status, text, usage, dt, err, used_json_mode = call_openai_compat(
                        "https://api.groq.com/openai/v1", key, model, prompt, json_mode)
                else:
                    status, text, usage, dt, err, used_json_mode = call_cohere(
                        key, model, prompt, json_mode)

                ok, detail = (False, "http error") if status != 200 else validate(pl, text)
                row = {"provider": provider, "model": model, "payload": pl, "status": status,
                       "schema_ok": ok, "detail": detail, "latency_s": round(dt, 2),
                       "json_mode": used_json_mode, "usage": usage, "error": err if status != 200 else ""}
                rows.append(row)
                if status != 200:
                    exit_bad = 1
                out = RESULTS / f"{provider}__{model.replace('/', '-')}__{pl}.json"
                out.write_text(json.dumps({"request_prompt": prompt, "response_text": text,
                                           **row}, indent=2, ensure_ascii=False))
                mark = "✅" if (status == 200 and ok) else "❌"
                print(f"{mark} {provider:<7} {model:<28} {pl:<5} "
                      f"HTTP {status} {'schema-OK' if ok else 'schema-FAIL: ' + detail} "
                      f"{dt:.1f}s" + (f"  [{err[:90]}]" if status != 200 else ""))

    # ---- summary table (machine-readable too)
    print("\n== summary ==")
    print(json.dumps(rows, ensure_ascii=False))
    (RESULTS / "summary.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False))
    return exit_bad


if __name__ == "__main__":
    sys.exit(main())
