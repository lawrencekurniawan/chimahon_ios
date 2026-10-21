# Chimahon iOS Spike

A throwaway vertical-slice app that validates the riskiest assumptions from
`../FEASIBILITY.md` before committing to the real port.

## What it validates

| Assumption | Result |
|---|---|
| hoshidicts (Yomitan dictionary engine, C++23) builds for iOS via SwiftPM | ✅ iOS 18+ / Xcode 27, `interopMode(.Cxx)` |
| Swift can drive the C++ engine (C++ interop + `CxxStdlib` string bridging) | ✅ works; `std::string` ↔ `String` via `import CxxStdlib` |
| Yomitan `.zip` import runs on-device | ✅ `dictionary_importer::import` |
| Deinflection (Yomitan transform rules) works | ✅ 食べました → 食べる with grammar trace |
| Term lookup + glossary rendering (incl. JSON glossaries) | ✅ |
| Frequency + pitch-accent meta banks | ✅ after registering the folder with `add_freq_dict`/`add_pitch_dict` |
| Kanji lookup | ✅ after `add_kanji_dict` |
| SwiftUI ↔ engine integration | ✅ |

## Key engine facts discovered (matters for the real app)

- **One imported folder serves all entry types**: the same path must be passed to
  `add_term_dict`, `add_freq_dict`, `add_pitch_dict`, and `add_kanji_dict`
  (per `ImportResult` counts — mirrors Android's `DictionaryTypes`/`DictionaryPaths`).
- `DictionaryQuery::query_raw` automatically enriches results with freq/pitch;
  `DictionaryQuery::query` additionally materializes (decompresses) glossaries —
  `Lookup::lookup` already does both internally.
- `std::unordered_map` members are not importable from Swift (kanji stats are
  skipped; use a C shim if needed later).
- hoshidicts needs its nested git submodules initialized (`git submodule update
  --init --recursive`) before the package resolves.

## Run

```sh
cd chimahon-spike
python3 tools/make_sample_dict.py   # crafts Resources/spike-dict.zip
xcodegen generate
open ChimahonSpike.xcodeproj        # or: xcodebuild -scheme ChimahonSpike \
                                    #     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Requires: Xcode 16+ (tested 27.1), iOS 18+ deployment target (hoshidicts
`Package.swift` platform floor).

Screenshots: `spike-screenshot.png` (deinflection), `spike-screenshot-kanji.png`
(freq + pitch + kanji).

## Status

Spike only — not product code. The real app starts per `../FEASIBILITY.md`
decisions: sideload distribution, manga + dictionary/Anki pillars, KMP hybrid.
