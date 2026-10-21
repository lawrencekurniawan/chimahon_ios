#!/usr/bin/env python3
"""Craft a minimal Yomitan-format dictionary zip for the iOS spike.

Format (validated against chimahon's hoshidicts importer):
  index.json                      - title/format/revision
  term_bank_1.json                - [[expr, reading, defTags, rules, score, glossary, seq, termTags], ...]
  term_meta_bank_1.json           - [[expr, "freq"|"pitch", data], ...]
  kanji_bank_1.json               - [[char, on, kun, tags, [defs], {stats}], ...]
"""
import json
import zipfile
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "spike-dict.zip"

index = {
    "title": "Spike Mini Dictionary",
    "format": 3,
    "revision": "1.0.0",
    "sequenced": True,
}

# expression, reading, defTags, rules, score, glossary, sequence, termTags
# rules use Yomitan identifiers so the deinflector can conjugate them.
terms = [
    ["食べる", "たべる", "", "v1", 1, ["to eat"], 1, ""],
    ["見る", "みる", "", "v1", 1, ["to see; to look; to watch"], 2, ""],
    ["行く", "いく", "", "v5k", 1, ["to go; to move"], 3, ""],
    ["来る", "くる", "", "vk", 1, ["to come"], 4, ""],
    ["買う", "かう", "", "v5u", 1, ["to buy; to purchase"], 5, ""],
    ["読む", "よむ", "", "v5m", 1, ["to read"], 6, ""],
    ["書く", "かく", "", "v5k", 1, ["to write"], 7, ""],
    ["飲む", "のむ", "", "v5m", 1, ["to drink"], 8, ""],
    ["する", "する", "", "vs", 1, ["to do; to perform"], 9, ""],
    ["犬", "いぬ", "", "", 0, ["dog; canine"], 10, ""],
    ["猫", "ねこ", "", "", 0, ["cat; feline"], 11, ""],
    ["水", "みず", "", "", 0, ["water"], 12, ""],
    ["本", "ほん", "", "", 0, ["book; volume; origin"], 13, ""],
    ["学ぶ", "まなぶ", "", "v5b", 1, ["to study; to learn"], 14, ""],
    ["学生", "がくせい", "", "", 0, ["student"], 15, ""],
    ["日本語", "にほんご", "", "", 0, ["Japanese language"], 16, ""],
    ["勉強", "べんきょう", "", "", 0, ["study; diligence"], 17, ""],
    ["言葉", "ことば", "", "", 0, ["word; language; expression"], 18, ""],
    ["辞書", "じしょ", "", "", 0, ["dictionary; lexicon"], 19, ""],
    ["読むこと", "よむこと", "", "", 0, ["reading (the act of)"], 20, ""],
]

# frequency: bare int or object both accepted by the importer
freqs = [
    ["犬", "freq", {"value": 1234, "displayValue": "1.2k"}],
    ["猫", "freq", 1500],
    ["食べる", "freq", {"value": 387, "displayValue": "387"}],
    ["日本語", "freq", {"value": 2050, "displayValue": "2.1k"}],
    ["本", "freq", {"value": 96, "displayValue": "96"}],
]

# pitch: {"reading": ..., "pitches": [{"position": n}, ...]}
pitches = [
    ["犬", "pitch", {"reading": "いぬ", "pitches": [{"position": 0}]}],
    ["猫", "pitch", {"reading": "ねこ", "pitches": [{"position": 0}]}],
    ["学生", "pitch", {"reading": "がくせい", "pitches": [{"position": 3}]}],
    ["勉強", "pitch", {"reading": "べんきょう", "pitches": [{"position": 3}]}],
]

kanji = [
    ["犬", "ケン", "いぬ", "", ["dog"], {"grade": "5", "strokes": "4"}],
    ["学", "ガク", "まな(ぶ)", "", ["study; learning; science"], {"grade": "1", "strokes": "8"}],
    ["水", "スイ", "みず", "", ["water"], {"grade": "1", "strokes": "4"}],
    ["本", "ホン", "もと", "", ["book; origin; main"], {"grade": "1", "strokes": "5"}],
]

OUT.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.json", json.dumps(index, ensure_ascii=False))
    z.writestr("term_bank_1.json", json.dumps(terms, ensure_ascii=False))
    z.writestr("term_meta_bank_1.json", json.dumps(freqs + pitches, ensure_ascii=False))
    z.writestr("kanji_bank_1.json", json.dumps(kanji, ensure_ascii=False))

print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
