# OCR Spike — Apple Vision on real nhattruyenqq pages

**Goal:** determine if Apple Vision can read Vietnamese comic bubble text
(stylized lettering, full diacritics) well enough for the split-screen
translation pipeline. Korean (ko-KR) also spot-checked for future sources.

## Test material

Real pages from `https://v1.beercloudy.com/nettruyen/fog-land/60/*.jpg`
(Referer-gated WebP masquerading as JPEG; converted to PNG via `sips`):

| File | Content | Notes |
|---|---|---|
| `fog60_0.png` | Promo/credits banner | mixed VN + EN, stencil/logo fonts, watermarks |
| `fog60_3.png` | Promo banner | low-contrast overlay text |
| `fog60_60.png` | Dialogue | **italic stylized** bubble: *CẢNH ĐẸP MÊ HỒN CHO ĐỜI TA,* |
| `fog60_80.png` | Dialogue | bold uppercase bubbles + pink watermark |
| `fog60_100.png` | Dialogue | bold uppercase bubbles |
| `ko_sample.png` | Synthetic Korean | rendered by `MakeKoreanSample` |

## Tools

- `VisionOCR/main.swift` — CLI OCR: `swift main.swift [--lang vi-VT|ko-KR] img...`
- `VisionOCR/debug*.swift` — language-combination experiments
- `MakeKoreanSample/main.swift` — renders the Korean test image

## Results

### Accuracy (Vietnamese, `vi-VT`, `.accurate` + language correction)

- **fog60_100:** character-perfect (7/7 lines, all 100% conf):
  `CÔ ẤY DẦN NHẬN RA NƠI NÀY TỒI TỆ ĐẾN MỨC NÀO.` /
  `SỰ TỒN TẠI CỦA FOG, MÔI TRƯỜNG CHÀ ĐẠP ĐẠO ĐỨC...`
- **fog60_80:** character-perfect on all bubble text (6/6 lines):
  `NHỮNG NGÀY ẤY VUI VẺ LẮM, CHẲNG AI ĐÁNH NHAU.` etc.
- **fog60_60 (italic stylized):** **3/3 character-perfect** including the
  tricky italic `CHO ĐÔI TA,` — initially logged as a Vision miss ( ĐÔI vs
  ĐỜI ) via a medium-zoom human read, but an extreme (1920px) zoom showed a
  clean symmetric circumflex `Ô` — **ground truth is ĐÔI, both engines were
  correct, the human read was wrong.** Lesson baked into pipeline design:
  don't trust single-pass low-zoom human verification either; engines agree
  with each other and with pixel evidence at high zoom.
- **fog60_0 (promo):** banner/stencil/logo text read well (`KAYNSCANS`,
  `CHAPTER 60 IS NOW AVAILABLE...`); stylized logo `TRUYENQQQ.COM` →
  `TRUYENCCC. COM` (expected — decorative Q's in circles). Watermarks
  (`DichTruyenAI.com`) correctly come back **low confidence (30–50%)** →
  filterable by confidence + y-position (top-of-page) + string matching.
- Mixed English within a Vietnamese page: read fine with `vi-VT` alone.

### Korean (`ko-KR`)

- Synthetic sample: **2/2 lines, confidence 1.0, character-perfect**
  (`안녕하세요, 오늘 날씨가 정말 좋네요!` / `너희들은 어디로 가고 있어요?`).
- Vietnamese page OCR'd with `ko` first: reads Latin text but **strips all
  diacritics** (`Thuc hien boi`, `CO AY DAN NAN`) — never mix.

### ⚠️ Critical API gotcha: `recognitionLanguages` is order-sensitive

Empirically "first language wins" (not a union):

| List | Korean sample | Vietnamese page |
|---|---|---|
| `["ko-KR"]` | ✅ 2 lines perfect | ⚠️ reads, diacritics stripped |
| `["vi-VT"]` | ❌ 0 lines | ✅ perfect |
| `["vi-VT","ko-KR"]` | ❌ 0 lines | ✅ perfect |
| `["ko-KR","vi-VT"]` | ✅ perfect | ⚠️ diacritics stripped |
| `["vi-VT","ko-KR","en-US"]` | ❌ 0 lines | ✅ perfect |

**Rule: pass exactly ONE language per request, chosen by known source
language.** The source knows its own language (nhattruyenqq → `vi-VT`;
future Korean source → `ko-KR`), so this is trivial to honor.
Also: the supported code for Vietnamese is **`vi-VT`, not `vi-VN`**
(`VNRecognizeTextRequest().supportedRecognitionLanguages()`).

### Performance (Apple Silicon, `.accurate`)

- 800×1500 page: **80–120 ms** steady-state (first call ~460 ms warmup);
  promo pages with more text ~460 ms.
- A 136-image webtoon chapter ≈ **12–20 s** OCR total — acceptable for
  background-on-load batching (and it caches after first pass).

## Verdict

**Apple Vision is good enough to be the primary OCR** for the split-reader
pipeline: near-perfect on standard bubble fonts including Vietnamese
diacritics, fast, free, on-device (privacy-friendly, no API cost). Design
carries two mitigations for the residual risk:

1. Confidence/position filtering kills watermarks & promo text.
2. LLM-vision re-check (same crop call as translate/explain) for bubbles
   where style is unusual — with per-segment provenance (§10) you can see
   which path produced each segment.

Note: `vi-VT` + `ko-KR` should be requested **separately** if a page's
language is unknown (2 passes), but source-known language avoids that.
## LLM-vision cross-check (2026-10-21, Gemini 3.8 Flash, `translation-spike/` key)

Same pages sent as `inline_data` images to the free-tier model:

- **fog60_100:** perfect — both bubbles verbatim with all diacritics
  (~1080 image tokens/page, ~120 out tokens).
- **fog60_60:** correct (`CHO ĐÔI TA,` — matches pixel truth at extreme zoom).
- Full-page vision pass can also return translations/word-by-word in one
  call — confirms the one-pass "OCR+translate+explain" fallback design.
- Throttling: same intermittent 503s as text calls; the failover retry loop
  (attempt 2–3 with backoff) always got through — validates the §10 chain.
- Blind language-prior disambiguation (candidates + context, no pixels)
  picked `đôi` — correct here, but it is a *prior*, not evidence; when a
  human disagrees with the engines, the tiebreaker is an extreme-zoom pixel
  check (which is how the fog60_60 "error" was resolved — in engines' favor).

**Cost note:** LLM vision OCR ≈ 1.1K tokens/page ≈ 150K tokens/chapter →
too expensive for bulk OCR on the free tier, perfect for occasional
re-checks of flagged bubbles. Apple Vision stays primary (free, on-device,
~100 ms/page); LLM-vision is the fallback for anything Vision flags
(low confidence, unusual style).
