#!/bin/zsh
# Translation-chain spike: Gemini free tier → structured explain JSON.
# Usage: ./translate_test.sh <model> <request.json>
# Key: set GEMINI_API_KEY env var (do NOT commit the key).
set -u
KEY="${GEMINI_API_KEY:?set GEMINI_API_KEY}"
MODEL="${1:-gemini-3.8-flash}"
REQ="${2:-requests/req_vi.json}"
curl -s -o /tmp/resp.json -w "code=%{http_code} time=%{time_total}s\n" --max-time 120 \
  "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${KEY}" \
  -H "Content-Type: application/json" -d @"${REQ}"
python3 - <<'PY'
import json
d = json.load(open('/tmp/resp.json'))
if 'error' in d:
    print("ERR:", d['error'].get('status'), d['error'].get('message', '')[:120])
else:
    t = d['candidates'][0]['content']['parts'][0]['text']
    print("model:", d.get('modelVersion'))
    md = d.get('usageMetadata', {})
    print("tokens in/out:", md.get('promptTokenCount'), md.get('candidatesTokenCount'))
    try:
        print(json.dumps(json.loads(t), ensure_ascii=False, indent=1)[:1200])
    except Exception:
        print("raw:", t[:600])
PY
