# Translation-Chain Spike — Gemini free tier (2026-10-21)

**Goal:** validate the zero-cost LLM translation/explain pipeline for the
split-screen reader (§10 of FEASIBILITY.md): structured JSON output
(`full_translation` + `word_by_word` + grammar notes), both languages, and
observe real free-tier throttling to design the failover chain.

## Setup

- Key: Google AI Studio free tier (stored in `.env`, NOT committed;
  ⚠️ the key was pasted in chat — consider it semi-exposed and rotate via
  AI Studio if worried).
- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/
  <model>:generateContent?key=<KEY>` with
  `generationConfig: {"responseMimeType":"application/json"}`.
- Requests in `requests/`: single VN bubble, single KO bubble, 3-bubble batch.

## Model availability findings

- **`gemini-2.5-flash` → 404 "no longer available to new users"** — new
  accounts must use current models. Usable from the 50-model list:
  `gemini-3.8-flash` (recommended), `gemini-3.5-flash-lite`,
  `gemini-3.1-flash-lite`, `gemini-flash-latest`, `gemini-omni-1.1`, TTS/
  image variants (not needed).
- Free tier service header: `x-gemini-service-tier: standard`.

## Quality results ✅

**Vietnamese → English explain** (`req_vi.json`, real Fog Land dialogue
*NHỮNG NGÀY ẤY VUI VẺ LẮM, CHẲNG AI ĐÁNH NHAU...*): perfect structured JSON —
correct full translation, 15 word-by-word entries with genuine Vietnamese
grammar notes ("Reciprocal pronoun 'nhau'", "Post-adjectival intensifier",
"Reduplicated descriptive adjective based on root 'vui'") + a tone/register
note (nostalgic/bittersitter framing). Exactly the user's example-popup
content, machine-generated.

**Korean → English** (`req_ko.json`): clean translations when the model
responds (see throttling below).

**Batch (3 bubbles/req)** (`req_batch.json`): correct id'd JSON array, all
3 bubbles translated with word-by-word, **11 s**, 165 in / 662 out tokens.
→ One 45-bubble chapter ≈ 2–3 batched requests ≈ ~2.5K in / ~10K out tokens
≈ comfortably under free-tier daily limits (hundreds of chapters/day).

## Throttling behavior (the thing the failover chain exists for) ⚠️

Observed in ~30 min of testing:
- **200 OK** with 7–17 s latency (flash) / 68 s (lite, under load).
- **503 `UNAVAILABLE` "high demand"** — intermittent, both flash and lite;
  sometimes back-to-back, sometimes clear after 10–60 s waits.
- Occasional instant **404 with empty body** (edge-level rejection under
  burst) — recovery: backoff + retry, same as 503.

→ Confirms design: rotation + cooldown + retry-with-jitter + per-segment
cache. Even at ~50% success rate, a chapter finishes in a couple of minutes
in background, once, then cached forever.

## Implications for the app (recorded in FEASIBILITY.md §9)

1. Working model for v1: **`gemini-3.8-flash` primary**, lite models as
   in-chain failover, Apple on-device as final offline fallback.
2. Schema-enforced JSON (`responseMimeType: application/json`) works
   reliably — no regex extraction needed.
3. Latency budget: batch per page-group (~5 bubbles), not per bubble.
4. Provenance logging (§10) will capture `modelVersion` straight from the
   response (`d.modelVersion`), plus token usage for cost/limit tracking.

## Files

- `translate_test.sh` — run any request against any model:
  `source .env; ./translate_test.sh gemini-3.8-flash requests/req_vi.json`
- `requests/req_vi.json` · `req_ko.json` · `req_batch.json`
- `.env` — key (local only)
