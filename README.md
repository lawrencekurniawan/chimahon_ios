# Chimahon iOS

Port of [Chimahon](https://github.com/Chimahon/chimahon) (Android, Kotlin) to
iOS — sideloaded manga reader with **Korean/Vietnamese → English** learning
tools: dictionary lookup, Anki mining, and a split-screen batch-translation
webtoon reader.

📖 **Full feasibility analysis + decisions: [`FEASIBILITY.md`](FEASIBILITY.md)**

## Status: feasibility spikes (pre-alpha)

| Spike | Verdict | Docs |
|---|---|---|
| C++ dictionary engine (hoshidicts) on iOS | ✅ confirmed | `chimahon-spike/README.md` |
| nhattruyenqq source (URLs, API, Cloudflare) | ✅ low risk | `FEASIBILITY.md` §11 |
| Apple Vision OCR (Vietnamese + Korean) | ✅ 100% on real pages | `ocr-spike/README.md` |
| LLM-vision OCR cross-check (Gemini) | ✅ perfect | `ocr-spike/README.md` |
| Free-tier translation chain (Gemini) | ✅ works + throttling mapped | `translation-spike/README.md` |
| WKWebView Cloudflare cookie-bridge | ✅ proven end-to-end | `cloudflare-spike/README.md` |

## Development workflow

Every milestone: **run the test gate → push only if green.**

```sh
./scripts/run_tests.sh   # must exit 0 before push
```

The gate runs: OCR regressions (needs fixtures), Gemini API contract checks
(needs `.env`), and the dictionary spike build (Xcode). Network/API tests
skip loudly when unconfigured rather than failing.

### Simulator policy

The developer runs other apps on this Mac's simulators. **All simulator
runs for this repo go through `./scripts/simulator.sh`**, which creates and
uses a dedicated device (`ChimahonSpike-iPhone17`) and never touches any
other simulator:

```sh
./scripts/simulator.sh erase-and-boot   # fresh dedicated device
./scripts/simulator.sh udid             # print its UDID for xcodebuild -destination
```

## First-time setup

```sh
# 1. upstream reference clone (gitignored, 127 MB — read-only reference for the port)
git clone --depth 1 https://github.com/Chimahon/chimahon chimahon-src

# 2. OCR test fixtures (not committed — copyrighted comic pages; re-downloaded)
ocr-spike/images/fetch_images.sh

# 3. secrets (never committed)
cp translation-spike/.env.example translation-spike/.env   # GEMINI_API_KEY=...
cp Secrets.example.xcconfig Secrets.xcconfig               # bundled key for builds
```

## Secrets policy

- Real API keys live only in gitignored `translation-spike/.env` and
  `Secrets.xcconfig` — templates are committed, secrets never are.
- The sideloaded build embeds a bundled key (obfuscated, read from
  `Secrets.xcconfig` at build time) so a fresh install needs **zero
  configuration**; Settings → Translation shows the active key (masked) and
  allows a per-device Keychain override. See `FEASIBILITY.md` §10.

## Layout

```
FEASIBILITY.md        # master analysis, decisions, spike results
chimahon-spike/       # dictionary engine (hoshidicts) SwiftUI spike
cloudflare-spike/     # WKWebView Cloudflare cookie-bridge spike
ocr-spike/            # Apple Vision + Gemini OCR tests, fixture fetcher
translation-spike/    # Gemini free-tier translation chain tests
scripts/run_tests.sh  # pre-push test gate
scripts/simulator.sh  # dedicated spike simulator (never personal devices)
```
