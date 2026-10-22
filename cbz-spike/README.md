# CBZ reader spike

Proves the **local-file half of the manga reader**: iOS can open a CBZ
(a ZIP of page images), read it fast, decode pages smoothly at phone
resolution, and render them in a webtoon-style lazy scroll — with
**zero third-party dependencies** (hand-rolled ZIP central-directory parser +
system zlib raw DEFLATE).

## Result (2026-10-22): ✅ PASS

Headless bench (24 synthetic pages, realistic 1600×3000 JPEG, dedicated sim):

| Metric | Result | Criterion |
|---|---|---|
| Page count read from archive | 24 / 24 | must equal 24 ✅ |
| **Byte-exact integrity** (inflate → CRC32 → compare vs originals) | all 24 pages identical | all ✅ |
| Archive open (EOCD + central directory parse) | **< 1 ms** | < 500 ms ✅ |
| First full-size decode | 14 ms | < 500 ms ✅ |
| Full decode average / max | **14 ms / 17 ms** | < 400 ms ✅ |
| Downsampled decode (production path, display height 1179×2210) | **36 ms avg** | < 150 ms ✅ |
| Decode failures / dimension mismatches | 0 / 0 | 0 ✅ |
| Memory delta across whole run (incl. fixture generation) | 25 MB | sane ✅ |
| Fixture CBZ size | 1.1 MB (24 pages) | info |

Interactive UI mode: `./run.sh ui` → LazyVStack reader, pages decode lazily on
appearance into an `NSCache`. Screenshot: `cbz-reader-screenshot.png`.

## What the spike found (matters for production)

1. **`UIGraphicsImageRenderer` defaults to screen scale (3×)** — a "1600×3000"
   render came out 4800×9000 on the simulator. Fixture/asset generators must
   pin `format.scale = 1` (or the target scale) explicitly.
2. **`CGImageSourceCreateImageAtIndex` returns *lazy* CGImages** — dimensions
   are known but pixels aren't decoded, which silently fakes ~0 ms decode
   timings. Benchmarks (and any code needing decoded pixels) must force
   rasterization (draw into a bitmap context). The production path uses
   `CGImageSourceCreateThumbnailAtIndex` (forced decode + downscale in one
   pass) — measured **36 ms/page**.
3. Sizes/CRC must come from the **central directory**, not local headers
   (streamed zips zero out local sizes behind data-descriptor flags).

## Reader architecture this validates

```
CBZ file → Data(.mappedIfSafe) → EOCD scan → central directory entries
   ↓ per visible page only (LazyVStack appearance)
local header → compressed slice → raw inflate (-15) → CRC verify
   ↓
ImageIO thumbnail at display height (1179×2210 @3x) → UIImage → NSCache
```

- Memory stays bounded: decode only what's on screen ± cache, proven by the
  25 MB delta over a full run.
- Zero dependencies: ZIP parsing + zlib only (both tiny/supported). If
  real-world CBZs ever hit ZIP64/bzip2/zstd edge cases, swap in ZIPFoundation
  (SPM) behind the same `ZipArchive` API — flagged in code comments.

## Known limitations (spike scope → production checklist)

- ZIP64 (>4 GB files or >65,335 entries) → explicit error (rare for chapter
  CBZs; production should handle or report cleanly).
- Compression methods: stored (0) + deflate (8) only. bzip2/zstd/lzma entries
  → clean "unsupported" error (some doujinshi rips use these → decide then).
- Page order = natural sort of entry names (works for `page_001.jpg`-style
  archives; ComicInfo.xml `<Pages>` ordering + directory entries are a
  production nicety, not proven here).
- No password-protected/encrypted zip support (CBZs with encryption are
  malformed for our purposes anyway).

## Run it

```sh
./run.sh      # headless bench → CBZ_VERDICT:{json}, exit 0/1
./run.sh ui   # interactive reader on the dedicated simulator
```

Uses the repo's **dedicated simulator** (`scripts/simulator.sh`) — never your
personal devices.
