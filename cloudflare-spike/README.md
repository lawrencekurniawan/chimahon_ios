# Cloudflare cookie-bridge spike

Proves **FEASIBILITY.md §11.4 rung 2**: a hidden WKWebView can solve (or
observe) a site's Cloudflare state, and URLSession can then reuse that exact
state — the fast path that avoids re-solving challenges on every request.

## Result (2026-10-22): ✅ PASS

| Check | Evidence |
|---|---|
| WKWebView loads nhattruyenqq.com (fresh device, zero prior state) | `loadFinished: true`, final URL `https://nhattruyenqq.com/` |
| Cookies harvested from `WKWebsiteDataStore.default().httpCookieStore` | `_ga`, `_ga_PJ0W4SDG1K`, `location` |
| **Bridge works** — cookies appear in outgoing URLSession request | `outgoingCookieHeaderHasAllTargetCookies: true` (verified via header-logging `URLProtocol`) |
| WebView's exact User-Agent reused on the wire | `userAgent == outgoingUA` — `Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 …) Mobile/15E148` |
| Real production API through bridged session | `ChapterList?slug=fog-land` → **200**, valid JSON, 15,700 bytes |
| Persistence across app relaunches | Run 2 (no erase): same cookies re-harvested, PASS, faster (19s vs 42s) |
| `cf_clearance` specifically | `false` — **no active wall right now** (§11 probe); the general cookie path that would carry it is proven |

## How it works

```
WKWebView (WKWebsiteDataStore.default, real browser JS/TLS context)
   │  loads target; if a CF challenge appears, wait for cf_clearance
   │  (poll up to -SettleSeconds; early-exit when it shows up)
   ▼
httpCookieStore.getAllCookies  ──►  HTTPCookieStorage.shared  (THE bridge)
   ▼
URLSession (config: httpCookieStorage = shared storage,
                httpAdditionalHeaders = WebView's navigator.userAgent,
                httpCookieAcceptPolicy = .always)
   ▼
Target API — cookies + UA attached by CFNetwork exactly like a browser
```

Two design points that matter for production:

1. **UA must match** — `cf_clearance` is bound to User-Agent + IP. The spike
   captures `navigator.userAgent` from inside the page (not a guess) and pins
   it on every URLSession used for the source.
2. **Custom `URLProtocol` classes replace cookie auto-attach** — if the
   production client ever installs a logging/intercept protocol, it must
   replicate cookie attachment itself (this spike's `HeaderLogURLProtocol`
   does; see its header comment).

## Production plan (§11.4 ladder)

- Rung 1 (prevention): one WebView session per launch, low request cadence.
- Rung 2 (this spike): cookie bridge for the fast path.
- Rung 3 (WebView-as-fetcher): if a JA3-level block appears, fetch HTML/JSON
  through the WebView itself via `evaluateJavaScript` + message handlers.
- Rung 4: tap-to-verify sheet — surface the WebView briefly when a challenge
  needs human-visible interaction.

If a challenge appears: same code path — the WebView solves it, `cf_clearance`
lands in the shared store, URLSession keeps working. The spike's `-TargetURL`
flag lets you point the whole test at any CF-protected site (e.g. the one
Tachimanga trips on) to watch it happen live.

## Run it

```sh
./run.sh                                    # target: nhattruyenqq.com
ERASE=1 ./run.sh                            # wipe cookie state first
./run.sh -TargetURL https://example.com     # any other site
```

Uses the repo's **dedicated simulator** (`scripts/simulator.sh`) — never your
personal devices. Prints one `BRIDGE_VERDICT:{json}` line; exit 0 = pass.
