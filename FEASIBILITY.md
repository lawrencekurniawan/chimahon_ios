# Chimahon → iOS Feasibility Analysis

Date: 2026-10-21
Source: https://github.com/Chimahon/chimahon (cloned to `chimahon-src/`, shallow)
Related: `Chimahon/hoshidicts` (C++ dictionary engine submodule), `Chimahon/chimahon-local-models`

---

## 1. What Chimahon actually is

A Mihon/Komikku (Tachiyomi-lineage) fork — an Android-only Kotlin app for language
immersion, combining:

| Pillar | Contents |
|---|---|
| **Manga** | Mihon core: library, downloads, CBZ/archive reading, community *extensions* (installable source APKs) |
| **Anime** | Aniyomi layer: mpv-based player, subtitles (.ass/libass), Jimaku, AniSkip, YouTube (NewPipe), torrent, Chromecast, anime extensions |
| **Novel** | In-house EPUB reader (WebView-rendered), OPDS, LNReader-style JS plugins |
| **Dictionary** | Yomitan-format dictionaries, native C++ engine (hoshidicts), WebView popup, pitch accent, 10+ language deinflectors |
| **OCR** | 3 engines: reverse-engineered Google Lens on-device (`.so`), PaddleOCR manga models, Mokuro pre-OCR; page lookup, screen lookup, video frame OCR |
| **Anki mining** | Yomitan-compatible marker engine, card creation, media, duplicate check |
| **Trackers/sync** | 15+ trackers (MAL, AniList, Kitsu, …) |

**Scale** (measured):

- 2,396 Kotlin files, **~365,000 LOC** Kotlin (301k of it in `app/` alone)
- 785 XML files, 755 files using Jetpack Compose, ~55 Voyager screens, ~100 screen models
- 55 SQLDelight `.sq` schemas + 58 migrations (schema at Mihon's v110+ scale)
- 21 Gradle modules; ~69 locales of i18n
- 11,093 commits, pushed daily → **actively developed upstream**

---

## 2. Headline verdict

**A literal, complete port of Chimahon to iOS is NOT feasible.** Two independent
reasons:

1. **Hard platform blockers** — several headline features have no iOS equivalent
   (see §4), most critically the extension ecosystem and cross-app screen OCR.
2. **Effort** — 365k LOC Android app; even with reuse, this is a multi-person-year
   project, and upstream moves daily (you'd be forking a moving target).

**A scoped iOS app covering Chimahon's immersion core IS feasible**, as a
ground-up rewrite with selective reuse of platform-neutral assets. Expect a
feature subset, not parity (see §5, §6).

**Precedent:** iOS manga readers exist in this space (e.g. Aidoku — WebAssembly
sources, sideloaded via SideStore/AltStore rather than the App Store), which
validates both the demand and the "sideload, don't App Store" distribution model
for apps of this type.

---

## 3. Effort model: what's portable vs. what isn't

Per-module analysis (files importing `android.`/`androidx.`):

| Module | LOC | Android-coupled files | Portability |
|---|---:|---:|---|
| `domain` | 12,683 | 9 / 359 (2.5%) | **Excellent** — near-pure Kotlin |
| `data` | 8,155 | 18 / 86 (21%) | Good — mainly SQLDelight drivers/paging |
| `source-api` | 6,551 | 19 / 97 | Good — already KMP `commonMain` |
| `chimahon` (dict/Anki/OCR core) | 20,131 | 18 / 88 | Good — JNI shims are the Android part |
| `core/*`, `source-local` | ~7,600 | mixed | Good |
| `presentation-core`/`-widget` | 6,523 | ~100% | UI — rewrite |
| **`app`** | **301,600** | 1,041 / 1,591 (65%) | **Full UI-layer rewrite** |

So roughly **~50k LOC of tested domain/business logic is potentially reusable**;
the 300k-LOC app layer is not.

Native/3rd-party dependencies and their iOS story:

| Dependency | Purpose | iOS story |
|---|---|---|
| **hoshidicts** (C++23, GPLv3, ~1MB) | Dictionary engine | ✅ Portable — CMake/clang arm64-ios, replace JNI shim (`hoshidicts_jni.cpp`) with a thin C/Swift bridge |
| **libarchive** | CBZ/ZIP/backup | ✅ Builds for iOS (or use ZIPFoundation for zip-only) |
| **QuickJS** (`quickjs-kt`) | JS plugins/extensions | ✅ Highly portable (or use JavaScriptCore) |
| **mpv + ffmpeg + libass + dav1d** | Anime player, frame/audio capture | ⚠️ iOS builds exist (mpv-kit, ffmpeg-iOS), but see GPL/App Store (§4.3) |
| **Google Lens on-device `.so`** | Primary OCR | ❌ Unportable — reverse-engineered init with hardcoded ELF offsets (`lens_asset_init.cpp`) |
| **PaddleOCR manga models** | Manga OCR | ⚠️ Weights are portable; needs Paddle-Lite/NCNN iOS runtime, or replace with Apple Vision |
| **Coil3, OkHttp, kotlinx.serialization, SQLDelight, moko-resources, Voyager** | infra | ✅ All have KMP/iOS stories |
| **Shizuku, PackageInstaller, MediaProjection, Glance widgets, WorkManager, AIDL, ViewBinding** | system integration | ❌ No iOS equivalents (analogue: WidgetKit, BGTaskScheduler — but only where applicable) |
| **NewPipeExtractor (YouTube)** | YouTube streaming | ❌ ToS + App Review risk |
| **DexClassLoader/PackageManager extension loading** | The extension ecosystem | ❌ Impossible on iOS (see §4.1) |

---

## 4. Hard blockers (features that cannot be ported as-is)

### 4.1 The extension system — the biggest one

Chimahon loads sources as **installed Android APKs** (`ExtensionLoader.kt` →
`PackageManager.getInstalledPackages`, `dalvik.system.PathClassLoader`,
signature verification, `PackageInstaller`/Shizuku installers). Hundreds of
third-party extensions are compiled Kotlin/Dex.

On iOS:
- **No dynamic code loading, period.** Guideline 2.5.2 prohibits apps from
  downloading or installing executables/interpreted code that alters app
  behavior. A JS/WASM "extension store" would be rejected on the App Store
  (Aidoku's WASM sources work only via sideloading).
- Alternatives, in decreasing order of fidelity:
  1. **Sideload-only build** with a QuickJS/WASM runtime (novel JS plugins in
     this repo already prove a JS path exists) — closest to parity, zero App Store.
  2. **Built-in sources** — reimplement a curated set (10–30 sites) natively in
     Swift inside the app — App Store viable, constant maintenance burden.
  3. **Declarative remote rules** (JSON selectors fetched at runtime, no code) —
     App Store grey area (reviewer-dependent); limited to what a rules DSL can express.
  4. **Server-side fetch/proxy** — you run the scrapers; app talks to your API.
     Technically clean but you assume liability for content and operating cost.

There is **no option that preserves "install any of 500+ community extensions" on
the App Store.** This is a product-defining constraint.

### 4.2 Screen OCR ("look up text in any app")

Implemented via **MediaProjection screen capture + a `TYPE_APPLICATION_OVERLAY`
floating button**. iOS has no overlay-over-other-apps and no general screen
capture (ReplayKit broadcast exists but gives you pixels of *your own or shared*
screen with no interactive tap-to-lookup in other apps' context, and iOS shows
recording indicators / restricts use). **Cross-app lookup: impossible.**
Workable iOS substitutes: in-app page OCR, camera OCR, and OCR of images picked
from Photos (all easy with Apple Vision).

### 4.3 License & distribution: GPLv3 vs App Store

The whole project is **GPL-3.0** (app + hoshidicts). Apple's App Store
developer agreement imposes usage restrictions (DRM, granularity of install,
content takedown powers) that are widely considered **incompatible with GPLv3**
(FSF position; historically GPLv3-incompatible apps have had App Store friction —
e.g. VLC's 2011 removal saga). Caveats: this is a legal-judgment area — get
advice before committing; many GPL apps do ship in practice. Your realistic
options:

- **Sideload distribution** (AltStore/SideStore, direct IPA) — no conflict, and
  unlocks blockers 4.1 (JS runtime) and the mpv/ffmpeg/GPL native stack. This is
  the path comparable apps take.
- **App Store** — requires a legal read on GPL, dropping/limiting native GPL
  components (ffmpeg/mpv: possible but costly — there are LGPL-ish configurations
  and ASL-style player alternatives), and §4.1/§4.4 compliance.
- Distribution question is **independent of the technical port** — decide first.

### 4.4 App Review / content policy (if targeting App Store)

- Many Mihon-ecosystem sources host unlicensed content → copyright rejection risk
  regardless of architecture.
- YouTube in-app streaming via NewPipe-style extraction violates YouTube ToS and
  review expectations.
- Torrent client inside the app → additional review risk.
- These are all avoidable by scoping them out of an App Store build.

### 4.5 Smaller platform mismatches

| Feature | iOS status |
|---|---|
| Anki mining | AnkiDroid **content provider** doesn't exist → swap the small `AnkiCardBridge` interface to **AnkiConnect** (desktop HTTP) / AnkiWeb / `.apkg` export. Easy. |
| Google Lens OCR engine | Replace with **Apple Vision** (`VNRecognizeTextRequest` — verify CJK quality for zh/ja/ko vertical/manga text) or PaddleOCR on Paddle-Lite/NCNN. Medium. |
| Shizuku, SAF folder pickers, APK updater | N/A — use Files app (`UIDocumentPicker`), in-app StoreKit/self-update rules |
| Widgets (Glance) | WidgetKit — rewrite, small |
| WorkManager | BGTaskScheduler — rewrite, small |
| Chromecast / Google Cast | Cast SDK exists for iOS; optional |
| Torrent server | likely drop |
| Backup format (protobuf+libarchive) | portable in principle; Android-side storage semantics differ |

---

## 5. Feasible scope tiers

**Tier 0 — Proof of life (1–2 wks):** Xcode project, SwiftUI shell, archive
(CBZ) + EPUB reading with page/chapter navigation.

**Tier 1 — Immersion MVP (≈2–4 months solo):**
Library/downloads (local files + a few built-in sources), manga reader with
OCR tap-to-lookup (Apple Vision), dictionary tab (hoshidicts built for iOS +
Yomitan import), dictionary popup, Anki card creation via AnkiConnect,
Mokuro support, tracker OAuth, settings/i18n foundation.

**Tier 2 — Anime + novels (≈+2–4 months):** mpv-based player (sideload build),
subtitles + Jimaku, video-frame OCR, EPUB reader polish, novel JS plugins,
WidgetKit widgets, background library updates.

**Tier 3 — Ecosystem ambitions (open-ended):** extension runtime (JS/WASM,
sideload), broad source parity, cloud sync — each is its own project.

Rough full-parity figure: **1–2 engineer-years+**, forever chasing a daily-moving
upstream. Treat Tier 1 as the realistic "convert to iOS" target.

---

## 6. Recommended approach (if you proceed)

**Hybrid: Kotlin Multiplatform for logic + native iOS UI.**

1. Promote `domain`, `data`, `source-api` (already 80–97% pure Kotlin) to true
   KMP with an iOS target — SQLDelight, OkHttp/Ktor, kotlinx.serialization all
   support this. Reuses ~50k LOC of tested logic + 55 schemas + 58 migrations.
2. Keep `chimahon/dictionary` + Anki marker engine as KMP/common Kotlin; link
   **hoshidicts via CMake** with a Swift-facing C header (drop the JNI shim).
3. Write UI in **SwiftUI** (Option A) or Compose Multiplatform for iOS
   (Option B). CMP reduces rewrite size (existing Compose code is a reference
   even if not directly reusable — it uses Android Compose Material3), but adds
   toolchain/maturity risk and still won't compile `app/` as-is (65% Android-
   coupled). SwiftUI is the safer long-term bet for a new app.
4. OCR: Apple Vision first (zero download, no model plumbing), PaddleOCR manga
   models as an accuracy fallback.
5. **Do not** attempt to carry: extension loader, Lens `.so`, screen-OCR
   overlay, Shizuku, Glance, WorkManager, torrent, YouTube extraction.
6. Decide distribution (§4.3) **before** choosing features — it gates the
   extension strategy, native GPL libs, and review risk.

Alternative rejected for comparison: full native Swift rewrite of everything
(cleanest result, throws away the 50k LOC of tested logic); and "just recompile
with Compose Multiplatform" (blocked by 65% Android coupling + Android-only
native deps).

---

## 7. Decision checklist — RESOLVED (2026-10-21, revised same day)

1. **Distribution:** **Sideload only** (AltStore/SideStore/direct IPA) — removes the GPL/App Store conflict and unlocks the full native stack; follows the Aidoku precedent. ✅
2. **Languages:** **Korean + Vietnamese, explained → English.** Japanese-specific parts (pitch accent, JP deinflection) de-scoped from v1; Korean deinflector + Korean/Vietnamese dictionaries in scope. ✅
3. **Primary source:** **nhattruyenqq.com** as a built-in native source (no extension runtime needed for v1); more VN/KR sources later. ✅
4. **Scope pillars:** Manga reader + source(s), Dictionary + Anki mining, **plus the split-screen batch-translation reader** (§10). Anime player and novel/EPUB reader deferred past v1. ✅
5. **Reader UX:** split-sync for **webtoons only** (auto-detected); paged manga → zoom reader + tap-to-explain popup; split ratio, font size, and **sync mode (translation-led vs lockstep) are settings**. ✅
6. **Translation engine:** zero-cost rotation chain (§10) — LLM free tiers + Apple on-device fallback + per-segment cache. ✅
7. **Reuse strategy:** **KMP hybrid** — promote `domain`/`data`/`source-api` to iOS targets; UI in SwiftUI. ✅
8. **License posture:** moot for v1 (sideload-only); revisit only if App Store is ever targeted.
9. **Upstream relationship:** TBD.

## 8. Risks (ranked)

1. Extension ecosystem unportable → product may lose its main differentiator.
2. App Store distribution may be incompatible (GPL + content + 2.5.2) → sideload-only may be the only path.
3. Scope creep toward parity with a 365k-LOC, daily-updated app.
4. OCR quality on stylized comic lettering — Vietnamese diacritics + Korean bubble text; benchmark Apple Vision against real nhattruyenqq pages early, with LLM-vision OCR as fallback.
4b. **Cloudflare/anti-bot escalation on nhattruyenqq** — user reports Tachimanga (iOS) is challenged on *every* session, so the site does challenge iOS-app clients even though raw curl passes today (IP reputation + TLS/JA3 fingerprint dependent; config can flip anytime). Mitigation designed in §11.4: challenge detection + `cf_clearance` cookie bridge via WKWebView + graceful in-app verification UX. If it ever escalates to non-bypassable JS challenges, the source degrades to "user taps Verify once per session" rather than breaking.
5. hoshidicts submodule license/build verified as portable (GPLv3 C++23, small — low risk, but confirm before depending on it).
6. Effort underestimation: Anki marker engine alone is 2.4k LOC with Yomitan test-fixture parity expectations.

---

## 9. Spike results (2026-10-21) — `chimahon-spike/`

**Verdict: the riskiest single assumption — that the C++ dictionary engine ports
to iOS — is CONFIRMED.**

Built a SwiftUI app (Xcode 27.1, iOS Simulator, iPhone 17 Pro) that:

- consumes hoshidicts directly as a SwiftPM package (`Package.swift`, C++23,
  `interoperabilityMode(.Cxx)` — iOS 18+ platform floor),
- imports a Yomitan-format `.zip` dictionary on-device,
- performs live lookup with deinflection (食べました → 食べる, full Yomitan
  grammar trace), glossary rendering, frequency badges (1.2k), pitch accent
  (↑0), and kanji entry lookup.

Notable findings (details in `chimahon-spike/README.md`):

- Swift C++ interop works well; `import CxxStdlib` provides `String` ↔
  `std::string` bridging.
- One imported dictionary folder must be registered under all four `add_*_dict`
  vectors (term/freq/pitch/kanji) — mirrors Android's `DictionaryTypes`.
- `std::unordered_map` is not importable from Swift (kanji `stats` omitted;
  a small C shim would cover it).
- hoshidicts has an MIT-licensed branch (`main-mit`) upstream — relevant if
  license flexibility is ever needed.

**Spike 2 — nhattruyenqq source:** ✅ low-risk, see §11 (API + URL formula,
Referer gating, Cloudflare ladder §11.4).

**Spike 3 — OCR on real Vietnamese webtoon pages** (2026-10-21,
`ocr-spike/`, Apple Vision vs real Fog Land ch.60 pages): ✅ **Vision is good
enough to be primary.**

- Standard bold/uppercase bubbles: **character-perfect at 100% confidence**,
  full Vietnamese diacritics (`SỰ TỒN TẠI CỦA FOG, MÔI TRƯỜNG CHÀ ĐẠP ĐẠO
  ĐỨC...`), 80–120 ms/page → a 136-image chapter ≈ 12–20 s.
- Stylized **italic** font: **3/3 character-perfect** — initially logged as
  a `ĐÔI`→`ĐỜI` miss, but extreme-zoom pixel verification (1920px) showed a
  clean circumflex: ground truth is `CHO ĐÔI TA,` and both engines were
  right; the low-zoom human read was the error. Net Vision result on real
  pages: **100% of dialogue text**. Still keep (a) confidence + y-position
  filtering (kills watermarks — they come back 30–50% conf) and (b)
  LLM-vision re-check as fallback for genuinely low-confidence bubbles.
- Korean `ko-KR`: perfect on synthetic sample (1.0 conf) — future sources OK.
- **API gotchas found:** (1) Vietnamese code is `vi-VT`, not `vi-VN`;
  (2) `recognitionLanguages` is effectively *first-language-wins* — passing
  `["vi-VT","ko-KR",…]` yields **0 Korean results**, and `ko` first strips
  Vietnamese diacritics → **exactly one language per request**, taken from the
  source's known language. Details + tables in `ocr-spike/README.md`.
- LLM-vision cross-check **DONE** (Gemini 3.8 Flash, spike 4 key): perfect on
  both bold and italic pages (~1.1K image tokens/page); confirms the
  one-pass "OCR+translate+explain" fallback path and that free-tier
  throttling is absorbed by the same failover retry loop.

**Spike 4 — Gemini free-tier translation chain** (2026-10-21,
`translation-spike/`, real Google AI Studio key): ✅ **zero-cost engine
confirmed viable.**

- Quality: real Fog Land dialogue → structured explain JSON
  (`full_translation` + `word_by_word` + grammar notes + tone/register) —
  matches the example-popup format; genuine Vietnamese grammar insights
  ("reciprocal pronoun nhau", "reduplicated adjective from root vui").
  Korean→EN works too. `responseMimeType: application/json` = reliable
  schema, no regex extraction.
- Batching: 3 bubbles/req in 11 s, 165/662 tokens → ~45-bubble chapter ≈
  2–3 requests ≈ 2.5K/10K tokens → hundreds of chapters/day inside free tier.
- **Model availability:** `gemini-2.5-flash` is *gone* for new accounts
  (404); sweep 2026-10-22 showed **`gemini-3.8-flash` is the ONLY callable
  text model on our key** — 10+ candidates tested (2.5/3.1/3.5/3.6/3.7-flash,
  `*-latest` aliases, gemma-4, 4-argon) all return instant empty 404; no
  callable flash-*lite* text model exists either. In-chain failover = other
  free providers (research spike, queued) + Apple on-device final fallback.
- **Throttling observed live:** intermittent `503 UNAVAILABLE` "high
  demand" (7–17 s success latency; occasional instant edge-404 under
  burst) — confirms the rotation/cooldown/backoff/jitter + per-segment
  cache design; even ~50% success rate finishes a chapter in background
  once, then it's cached forever.
- Provenance: response carries `modelVersion` + `usageMetadata` → feed
  §10's per-segment model note and token accounting directly from it.
- Key stored in `translation-spike/.env` (local only; pasted in chat →
  rotate via AI Studio if concerned).

**Not yet validated** (next candidates): KMP iOS target compilation of
`domain`, AnkiConnect-based card creation. ~~WKWebView Cloudflare
cookie-bridge (§11.4 rung 2)~~ ✅ proven 2026-10-22; ~~CBZ reading + page
rendering~~ ✅ proven 2026-10-22 (`cbz-spike/`: 24/24 pages byte-exact,
open <1 ms, production downsampled decode 36 ms/page, lazy scroll UI —
zero-dependency ZIP+zlib reader; two gotchas documented: renderer screen
scale3× and lazy CGImage fake timings).

---

## 10. Split-screen batch-translation reader (scoped 2026-10-21)

**Goal:** top pane = English translation (full + word-by-word + grammar) of the
comic text, bottom pane = original comic; one gesture scrolls both; size and
sync behavior are settings; chapters batch-translated in the background on load.

### Format gating (decided)

- **Webtoon/vertical strips (primary):** split-sync mode. One virtual scroll
  position per chapter; each bubble-segment anchors its comic y-range and its
  translation block to the same timeline point. Sync modes (setting):
  - *translation-led*: comic advances segment-by-segment as its translation is
    read ("comic doesn't move until translation ends").
  - *lockstep*: both panes move continuously, anchored per segment.
- **Paged manga:** NOT split-synced (zoom makes text unreadable at half-screen;
  zoom/sync mapping explodes in edge cases). Instead: zoomable reader +
  tap-to-explain popup (original / full EN translation / word-by-word / grammar —
  same backend as split mode).

### Pipeline

download chapter → OCR bubble crops → translate+explain (structured JSON) →
cache in SQLite (keyed by content hash; everything works offline after first
load) → render in split pane; prefetch next chapter in background (BGTask).

### Engine: zero-cost rotation chain (user requirement: pay nothing)

Reality check baked in:
- "ChatGPT" and "DeepSeek" official APIs are **paid** (no free tier) — not usable
  per the $0 requirement; "iCloud Pro" is not an API (iCloud = storage; Apple
  Private Cloud Compute is not exposed to third-party apps).
- Actual free building blocks:
  1. **Gemini API free tier** (AI Studio) — generous (~15 req/min, ~1M tokens/day
     on flash models), strong at ko/vi → en. Primary.
  2. **Other free tiers** for failover: Groq, OpenRouter free models, Cerebras.
  3. **Apple on-device**: `FoundationModels` (iOS 26, Apple Intelligence — free,
     offline, ideal fallback) and the Translation framework (sentence-level).
  4. User-supplied API keys as an optional quality boost later.

Architecture: `TranslationProvider` protocol + **failover chain with rotation,
cooldown/circuit-breaker on timeout/429, per-segment caching** so each line is
translated exactly once. Batch requests bundle a whole page's bubbles (~1 chapter
≈ a few K tokens ≈ free-tier dust). Estimated total cost: **$0**, bounded only
by free-tier rate limits (fine for personal reading volume).

#### Confirmed engine strategy (user 2026-10-22) + measured quota reality

Measured 2026-10-22: the optimistic assumption above ("~15 req/min, ~1M
tokens/day") is **wrong for this key/model** — after ~1 day of spike testing
the `gemini-3.8-flash` free quota hit `generate_content_free_tier_requests
limit: 20` with **"retry in 6h38m"**, i.e. a small multi-hour window, not a
per-minute limit. Plan accordingly:

1. **Cache-first, request-minimal:** per-segment SQLite cache (each line
   translated once, ever) + aggressive batching (whole page/chapter per
   request — measured 3 bubbles/req → push toward ~45 bubbles/req) + retry
   with backoff on 429. v1 model: **`gemini-3.8-flash`** (only callable model;
   retest `*-lite` variants when re-evaluating).
2. **Apple on-device = interim fallback only.** User explicitly flags quality
   concern — "i'm afraid the on-device fallback is not good enough." Treat as
   degraded mode pending provider research; label it loudly in UI (§ provenance).
3. **Queued spike: research other free providers** (OpenRouter free models,
   Groq, Cerebras, …) to become real alternate rungs in the chain — this is
   the mitigation for both quota exhaustion and on-device quality.
4. **Provenance = quality triage.** Every translation shows which model
   produced it (already § provenance; reaffirmed): the user will review
   labels and comment whether each model's quality is good enough —
   especially `on-device` vs `gemini-3.8-flash` — and those judgments drive
   chain ordering and the re-translate-with-next-model action.
5. **Measure the real budget:** log 429 resets + daily request counts during
   early real reading; decide on a 2nd Google project/key (key-level
   rotation) only if measured usage exceeds one key's window.

### Translation provenance (decided 2026-10-21)

**Every translated segment records which model produced it.** Cache schema adds
`provider_id`, `model_id` (e.g. `google/gemini-2.0-flash`, `groq/llama-3.3-70b`,
`apple/foundation-models-on-device`), `prompt_version`, `translated_at` per
SQLite row. Display:

- Subtle model label under/next to each translation block in the split pane
  (and in the tap-to-explain popup) — e.g. `✦ gemini-flash` or `/on-device`.
- Toggle in settings ("Show translation model"); on by default.
- Tap the label → detail sheet: provider, model, latency, timestamp, retry
  count — makes free-tier quality comparison and rotation debugging possible.
- Retranslation action ("Re-translate with next model") uses this to compare.

### API key strategy for sideloaded builds (decided 2026-10-21)

**Goal: sideload once → zero configuration.** No manual key entry on install.

- **Bundled default key:** compiled into the app from a **gitignored local
  `Secrets.xcconfig`** (public repo ships only `Secrets.example.xcconfig`
  template). Runtime decryption/obfuscation so the raw string isn't trivially
  greppable from the binary — honest caveat: client-side crypto is
  obfuscation, not secrecy; acceptable for personal sideload distribution.
- **Settings → Translation shows the active key:** masked (`AQ.Ab8R…WMA`),
  source badge (**Bundled** / **Custom**), project id, and last-used status
  (e.g. "429 quota hit 14:32").
- **Override:** "Use my own key" → stored in **Keychain** (per-device),
  "Reset to bundled default" clears it. Precedence: Keychain override >
  bundled default. Rationale: bundled key shares one free-tier quota —
  power users can add their own without waiting for an app update.
- Rotation: change local `Secrets.xcconfig` + rebuild; user keys change
  in-app instantly.

### Difficulty verdict

Webtoon split + batch pipeline: **moderate — ~2–4 weeks** inside the app.
Paged-manga split-sync: **hard; excluded by design** (popup instead).
Biggest risk: **OCR accuracy on stylized bubble lettering** (Vietnamese
diacritics + Korean) — spike Apple Vision against real nhattruyenqq pages and
fall back to LLM-vision OCR (same crop-based call as translate/explain) if
needed.



## 11. nhattruyenqq.com source probe (2026-10-21) — VERDICT: straightforward ✅

No Cloudflare challenge on plain HTTP fetches (curl/webfetch both get full
HTML). ASP.NET WebForms + jQuery site.

**URL scheme**
- Series: `/truyen-tranh/<slug>` (e.g. `/truyen-tranh/fog-land`)
- Chapter: `/truyen-tranh/<slug>/chuong-<n>` (e.g. `/chuong-60`; `/chuong-0` = oneshot)
- Browse: `/tim-truyen?page=N` (772 pages), genres `/tim-truyen/<genre>`,
  search: `/tim-truyen?keyword=<q>` (works; disallowed by robots.txt for
  crawlers — see note below)
- Sitemap: `/sitemap.xml` → per-1000-series `sitemap-comic-N.xml` (full series index)

**Chapter list API (the key find)**
- `GET /Comic/Services/ComicService.asmx/ChapterList?slug=<slug>` with
  `Accept: application/json` (GET, not POST!) returns JSON with **all**
  chapters: `chapter_id`, `chapter_num`, `chapter_name`, `image_num`
  (page count per chapter), `cdn_sv`, `image_type`, `updated_at`.
  Used by the site's own `getChapterList()` in `main.js`.

**Page images (already server-rendered — no JS execution needed)**
- `<img class='lozad' data-src='https://v1.beercloudy.com/nettruyen/<slug>/<chapterNum>/<i>.jpg' data-sv1=... data-sv2=... referrerpolicy='origin'>`
- `i` = 0 … image_num-1 (image_num also comes from ChapterList API — no HTML
  parsing strictly required for page URLs).
- **Hotlink protection: `Referer` must be an nhattruyenqq.com URL** (any path);
  missing/wrong Referer → 403. UA not gated. Easy in URLSession
  (`setValue("https://nhattruyenqq.com/", forHTTPHeaderField: "Referer")`).
- Dual servers (`data-sv1`/`data-sv2`) exist for failover, but v1.beercloudy
  currently serves both values.
- Response is **WebP bytes with `Content-Type: image/jpeg`** and `.jpg` URL —
  decode by content sniffing (iOS `UIImage`/`CGImageSource` handle this natively).
- Sampled fog-land ch60: 136 images, all 800×1500 (vertical webtoon strips —
  ideal for split-screen mode).

**Other observations**
- `window.chapterData` embedded JSON on chapter pages: id/slug/chapterId/
  chapterNum/chapterName/chapterUrl — convenient parser anchor.
- Ads: ~4 non-content imgs per page (acscdn/aqle3 networks) — filter by
  `beercloudy.com` host. Ad scripts are site-side; app only parses HTML.
- robots.txt disallows `/tim-truyen?keyword=*` and `/api/*` for crawlers
  (keyword search still functions; sitemap + browse are explicitly allowed).
  Sideloading a personal reader ≠ crawler, but: (a) hammering search is
  discouraged — prefer sitemap/browse for discovery, (b) rate-limit politely,
  (c) this is aggregator-scanlation content — personal-use assumption.
- ASP.NET `__VIEWSTATE`/csrf tokens exist but only matter for POST actions
  (login/follow/history) — v1 read path is all GET.

**Conclusion:** source implementation risk dropped from "unknown" to **low**.
A native Swift source needs: series list (browse/sitemap), chapter list
(ChapterList API), page URLs (formula or `<img data-src>` regex + Referer
header). Est. ~2–3 days of work incl. tests.

### 11.4 Anti-bot / Cloudflare preparedness (user report 2026-10-21)

**User report:** Tachimanga (iOS) hits a Cloudflare challenge on nhattruyenqq
essentially every session — so the site *does* challenge iOS-app clients, even
though plain `curl` from this Mac currently sails through (200 for every UA,
HTTP/1.1 and h2, 10-request burst all 200, no `cf-chl` markers in pages).
Challenge triggering is reputation-dependent (IP, TLS/JA3 fingerprint of
URLSession vs Safari, request cadence, cookie state) and the site owner can
flip "Under Attack Mode" anytime. **Design assumption: challenges WILL happen;
treat them as a normal code path, not an error.**

**Defense layers observed (probe 2026-10-21):**
1. **Cloudflare edge** in front of the site (`server: cloudflare`, `cf-ray`,
   NEL, `cf-cache-status`).
2. **Referer gating on the image CDN** (B2-backed, `x-bz-*` headers): 403
   without an nhattruyenqq.com Referer — already handled (§11).
3. **ASP.NET WebForms tokens** (`__VIEWSTATE`, `window.token`, csrf) — only
   for POST actions (login/follow/history); v1 read path is GET-only.
4. **Client fingerprinting scripts** (`fingerprint2.min.js`) + ad-network
   scripts — page-side; only matter if we run JS (we don't in fast path).
5. **robots.txt** crawling constraints (keyword search, /api/*).

**Planned countermeasure ladder** (each rung tries the next automatically):

- **Rung 0 — prevention.** Browser-like headers (UA = a real Safari-iOS
  string, `Accept`/`Accept-Language`, `Accept-Encoding`), referer on CDN
  hits, polite rate limit (e.g. ≤1 req/s with jitter), aggressive local
  caching (chapters are immutable once downloaded → never refetch), prefer
  browse/sitemap/ChapterList API over search. Keep sessions warm (periodic
  benign request) so `cf_clearance` doesn't lapse.
- **Rung 1 — challenge detection.** Treat as challenge (not failure): HTTP
  403/503, or body contains `Just a moment`, `cf-chl`, `challenge-platform`,
  or **missing the page's own marker** (`window.chapterData` absent / zero
  `beercloudy` image URLs). Detect per-URL so only the challenged fetch is
  retried.
- **Rung 2 — cookie bridge.** Load the challenged URL once in a hidden
  **WKWebView**, let the challenge solve itself (WebKit JS engine + real
  Safari TLS fingerprint), then harvest `cf_clearance` (+ `__cf_bm`) from
  `WKWebsiteDataStore.default().httpCookieStore` and inject into
  `HTTPCookieStorage` for URLSession, together with **the WebView's exact
  User-Agent** (cf_clearance is UA+IP bound — swapping UA invalidates it).
  Subsequent fast-path fetches reuse the cookie until expiry (cf clearance
  typically ~30 min–days; refresh proactively).
- **Rung 3 — WebView-as-fetcher fallback.** If URLSession is challenged even
  *with* a valid clearance cookie (JA3 mismatch scenario): fetch HTML through
  the persistent WKWebView (`evaluateJavaScript` / DOM extraction) instead.
  Slower, but WebKit passes what URLSession cannot. Images mostly stay on the
  CDN (referer-gated, not CF-challenged) so the fallback only costs the
  HTML/API rungs.
- **Rung 4 — user-visible verification.** If auto-solve fails (interactive
  checkbox/Turnstile): in-app sheet "Tap to verify nhattruyenqq" showing the
  WebView; one tap, then resume normal fetches. Never a dead end.

**Engineering notes:**
- Wrap all of this behind one `SourceFetcher` protocol so the challenge logic
  is written once and reused by future sources (Korean/Vietnamese sites have
  their own Cloudflare and other anti-bot variants).
- URLSession's TLS fingerprint (JA3/JA4) differs from Safari's; iOS gives no
  supported way to customize it → that's exactly why rungs 2–3 exist, and why
  we do **not** attempt JA3 spoofing (private API territory).
- Persist cookie state + last-verified timestamp in the Keychain-adjacent
  cookie store; re-verify on app launch if stale.
- Chapter/image URLs are deterministic (§11) → after first successful fetch,
  everything is cached locally and challenge risk drops to ~zero for reading.
- **Risk ranking:** moved to §8 (4b) — degraded mode is "one tap per session",
  matching what Tachimanga users already accept today.

**Spike item added:** simulate/observe a real challenge from an iOS client
(WKWebView load of nhattruyenqq in the spike app) and prove the
cookie-bridge path end-to-end before building the full source.

**Spike result (2026-10-22): ✅ rung 2 proven end-to-end** (`cloudflare-spike/`).
Fresh simulator (zero prior cookies) → hidden WKWebView loaded
nhattruyenqq.com → cookies (`location`, `_ga`, `_ga_PJ0W4SDG1K`) harvested
from `WKWebsiteDataStore.default().httpCookieStore` → bridged into
`HTTPCookieStorage.shared` → outgoing URLSession request provably carried
**all target-domain cookies + the WebView's exact `navigator.userAgent`**
(verified with a header-logging `URLProtocol`) → real production endpoint
`ChapterList?slug=fog-land` answered **200 + valid JSON (15.7 KB)** through
the bridged session. Relaunch persistence re-verified (second run, no erase:
same cookies, PASS). `cf_clearance` itself was `false` — no active wall at
probe time (§11) — but the exact cookie path that would carry it is proven;
`run.sh -TargetURL <any CF site>` replays the whole test against a real
challenge when one is visible. Two production-critical gotchas learned:
(a) capture the UA from inside the page (`navigator.userAgent`), never guess
it — clearance cookies are UA+IP bound; (b) a custom `URLProtocol` in a
session's `protocolClasses` **replaces** the system cookie auto-attach, so
any future intercept/debug layer must re-attach cookies itself.
