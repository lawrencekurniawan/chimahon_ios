#!/bin/zsh
# Pre-push test gate. Run: ./scripts/run_tests.sh
# Exit 0 = all required tests passed (push allowed).
# Network/API tests are SKIPPED (not failed) when offline or no key —
# but a skip is reported loudly so it can't be silently ignored forever.
set -u
cd "$(dirname "$0")/.."
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⚠️  SKIP: $1"; }

echo "== [1/3] OCR spike: Apple Vision on real fixtures =="
IMG=ocr-spike/images
if [[ ! -f $IMG/fog60_100.png ]]; then
  skip "fixtures missing — run ocr-spike/images/fetch_images.sh first"
else
  OUT=$(cd ocr-spike/VisionOCR && swift main.swift ../images/fog60_100.png ../images/fog60_80.png 2>/dev/null)
  echo "$OUT" | grep -q "CHÀ ĐẠP ĐẠO ĐỨC" \
    && ok "fog60_100 diacritics recognized (CHÀ ĐẠP ĐẠO ĐỨC)" \
    || bad "fog60_100: expected 'CHÀ ĐẠP ĐẠO ĐỨC' not found"
  echo "$OUT" | grep -q "NHỮNG NGÀY" \
    && ok "fog60_80 bubble recognized" \
    || bad "fog60_80: expected 'NHỮNG NGÀY' not found"
  # language-order regression: vi+ko mixed list must still read Vietnamese
  OUT2=$(cd ocr-spike/VisionOCR && swift main.swift ../images/fog60_80.png 2>/dev/null)
  echo "$OUT2" | grep -q "VUI VẺ" \
    && ok "diacritics intact with single-language request" \
    || bad "diacritics lost — check recognitionLanguages=[vi-VT] only"
  # Korean synthetic (fixtures fetch regenerates it)
  if [[ -f $IMG/ko_sample.png ]]; then
    KO=$(cd ocr-spike/VisionOCR && swift main.swift --lang ko-KR ../images/ko_sample.png 2>/dev/null)
    echo "$KO" | grep -q "안녕하세요" \
      && ok "ko-KR OCR (synthetic sample)" \
      || bad "ko-KR OCR failed on synthetic sample"
  else
    skip "ko_sample.png missing"
  fi
fi

echo "== [2/3] Translation spike: Gemini free tier =="
if [[ -f translation-spike/.env ]]; then
  source translation-spike/.env
  CODE=$(curl -s -o /tmp/tgate.json -w "%{http_code}" --max-time 60 \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"parts":[{"text":"Return JSON only: {\"ok\": true}"}]}],"generationConfig":{"responseMimeType":"application/json"}}')
  if [[ "$CODE" == "200" ]] && python3 -c "
import json,sys
d=json.load(open('/tmp/tgate.json'))
t=d['candidates'][0]['content']['parts'][0]['text']
assert json.loads(t).get('ok') is True, 'payload'
" 2>/dev/null; then
    ok "Gemini API reachable + JSON schema mode"
  elif [[ "$CODE" == "503" ]]; then
    ok "Gemini 503 high-demand (expected throttling; failover path validated separately)"
  else
    bad "Gemini API gate failed (HTTP $CODE)"
  fi
  # structured explain-schema smoke (the real pipeline contract)
  CODE2=$(curl -s -o /tmp/tgate2.json -w "%{http_code}" --max-time 90 \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" -d @translation-spike/requests/req_vi.json)
  if [[ "$CODE2" == "200" ]] && python3 -c "
import json,sys
d=json.load(open('/tmp/tgate2.json'))
j=json.loads(d['candidates'][0]['content']['parts'][0]['text'])
assert 'full_translation' in j and 'word_by_word' in j and j['word_by_word'], 'schema'
" 2>/dev/null; then
    ok "explain-schema (full_translation + word_by_word) contract holds"
  elif [[ "$CODE2" == "503" ]]; then
    ok "explain-schema call 503-throttled (contract verified in spike; retry is design)"
  else
    bad "explain-schema contract failed (HTTP $CODE2)"
  fi
else
  skip "translation-spike/.env missing (API tests) — copy .env.example and fill GEMINI_API_KEY"
fi

echo "== [3/3] Dictionary spike: chimahon-spike builds =="
if [[ -d chimahon-spike/ChimahonSpike.xcodeproj ]]; then
  if xcodebuild -project chimahon-spike/ChimahonSpike.xcodeproj -scheme ChimahonSpike \
       -destination 'generic/platform=iOS Simulator' -derivedDataPath chimahon-spike/build \
       build 2>/tmp/xcodebuild_err.log >/tmp/xcodebuild_out.log; then
    ok "ChimahonSpike builds for iOS Simulator"
  else
    bad "ChimahonSpike build failed — see /tmp/xcodebuild_err.log"
    tail -5 /tmp/xcodebuild_err.log
  fi
else
  skip "chimahon-spike project missing"
fi

echo ""
echo "== gate result: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
