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

echo "== [1/5] OCR spike: Apple Vision on real fixtures =="
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

echo "== [2/5] Translation spike: Gemini free tier =="
if [[ -f translation-spike/.env ]]; then
  source translation-spike/.env

  # Bounded redial (2026-10-22): 503/000/429 at the edge are transient —
  # the spike and probes observed success on redial within seconds, and a
  # single-shot gate run got unlucky while the API answered 200 moments
  # later. STRICT semantics unchanged: only an actual HTTP 200 with a valid
  # payload can pass; retries redial transient statuses, never relax them.
  gemini_call() { # $1=req-body file  $2=out file → sets CODE to LAST attempt
    local body="$1" out="$2" attempt
    CODE=000
    for attempt in 1 2 3; do
      CODE=$(curl -s -o "$out" -w "%{http_code}" --max-time 90 \
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" -d @"$body")
      case "$CODE" in
        200) return 0 ;;
        000|429|503) [[ $attempt -lt 3 ]] && sleep $((attempt * 5)) ;;
        *) return 1 ;;  # non-transient status — redialing won't help
      esac
    done
    return 1
  }

  classify_fail() { # $1=check name  $2=tempfile with error body
    local name="$1" f="$2" hint
    case "$CODE" in
      503) bad "$name 503 high-demand after 3 redials — API not answering OK (blocks push)" ;;
      429)
        hint=$(grep -o 'Please retry in [^.]*' "$f" | head -1 || true)
        bad "$name quota exhausted (429${hint:+ — $hint}) after 3 redials — blocks push until API recovers"
        ;;
      000) bad "$name unreachable (curl HTTP 000) after 3 redials — network problem, API not answering OK (blocks push)" ;;
      *)   bad "$name gate failed (HTTP $CODE)" ;;
    esac
  }

  printf '%s' '{"contents":[{"parts":[{"text":"Return JSON only: {\"ok\": true}"}]}],"generationConfig":{"responseMimeType":"application/json"}}' > /tmp/tgate_req.json
  if gemini_call /tmp/tgate_req.json /tmp/tgate.json; then
    if python3 -c "
import json,sys
d=json.load(open('/tmp/tgate.json'))
t=d['candidates'][0]['content']['parts'][0]['text']
assert json.loads(t).get('ok') is True, 'payload'
" 2>/dev/null; then
      ok "Gemini API reachable + JSON schema mode"
    else
      bad "Gemini replied 200 but JSON-mode payload invalid"
    fi
  else
    classify_fail "Gemini" /tmp/tgate.json
  fi

  # structured explain-schema smoke (the real pipeline contract)
  if gemini_call translation-spike/requests/req_vi.json /tmp/tgate2.json; then
    if python3 -c "
import json,sys
d=json.load(open('/tmp/tgate2.json'))
j=json.loads(d['candidates'][0]['content']['parts'][0]['text'])
assert 'full_translation' in j and 'word_by_word' in j and j['word_by_word'], 'schema'
" 2>/dev/null; then
      ok "explain-schema (full_translation + word_by_word) contract holds"
    else
      bad "explain-schema replied 200 but payload invalid"
    fi
  else
    classify_fail "explain-schema" /tmp/tgate2.json
  fi
else
  skip "translation-spike/.env missing (API tests) — copy .env.example and fill GEMINI_API_KEY"
fi

echo "== [3/5] Dictionary spike: chimahon-spike builds =="
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

echo "== [4/5] Cloudflare spike: builds for iOS Simulator =="
# Build-only by design: the LIVE bridge test (cloudflare-spike/run.sh, needs
# simulator + live site) is run at spike time, not every gate — site downtime
# must not block unrelated milestone pushes.
if [[ -d cloudflare-spike/Sources ]]; then
  if (cd cloudflare-spike && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project CloudflareBridge.xcodeproj -scheme CloudflareBridge \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
        build >/tmp/cfbridge_build.log 2>&1); then
    ok "CloudflareBridge spike builds for iOS Simulator"
  else
    bad "CloudflareBridge spike build failed — see /tmp/cfbridge_build.log"
    tail -5 /tmp/cfbridge_build.log
  fi
else
  skip "cloudflare-spike missing"
fi

echo "== [5/5] CBZ spike: builds for iOS Simulator =="
if [[ -d cbz-spike/Sources ]]; then
  if (cd cbz-spike && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project CbzSpike.xcodeproj -scheme CbzSpike \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
        build >/tmp/cbz_build.log 2>&1); then
    ok "CbzSpike spike builds for iOS Simulator"
  else
    bad "CbzSpike spike build failed — see /tmp/cbz_build.log"
    tail -5 /tmp/cbz_build.log
  fi
else
  skip "cbz-spike missing"
fi

echo ""
echo "== gate result: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
