#!/bin/zsh
# Re-creates the local OCR test fixtures (not committed — copyrighted pages).
# Deterministic nhattruyenqq URLs (FEASIBILITY.md §11): needs a Referer header.
# Usage: ./fetch_images.sh
set -eu
cd "$(dirname "$0")"

mkdir -p images && cd images
REFERER="https://nhattruyenqq.com/"
BASE="https://v1.beercloudy.com/nettruyen/fog-land/60"

# Fog Land ch60 pages used by the spike: promos + dialogue samples
for i in 0 1 2 3 4 5 40 60 80 100; do
  if [[ -f fog60_$i.png ]]; then echo "skip fog60_$i (exists)"; continue; fi
  echo "fetching page $i..."
  curl -sf -H "Referer: $REFERER" -o fog60_$i.img "$BASE/$i.jpg"
  # Content is WebP despite .jpg URL/content-type; normalize to PNG
  sips -s format png fog60_$i.img --out fog60_$i.png >/dev/null 2>&1
  rm -f fog60_$i.img
done

# Synthetic Korean sample (generated, safe to commit — but regenerated anyway)
if [[ ! -f ko_sample.png ]]; then
  echo "generating ko_sample.png..."
  (cd ../MakeKoreanSample && swift main.swift)
fi

echo "done: $(ls *.png | wc -l | tr -d ' ') png fixtures in $(pwd)"
