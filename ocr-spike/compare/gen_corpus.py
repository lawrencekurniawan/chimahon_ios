#!/usr/bin/env python3
"""
Synthetic OCR ground-truth corpus: comic-style pages with KNOWN text rendered
in tricky lettering styles → measured character error rate for Apple Vision
vs Gemini vision (comprehensive comparison, 2026-10-22).

Deterministic (seeded blobs). Usage:
    ./venv/bin/python gen_corpus.py
Output:
    corpus/*.png          800x1500 pages (gitignored — regenerable)
    manifest.json         ground truth: [{id, file, lang, style, text}]
"""
import json
import os
import random

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "corpus")
W, H = 800, 1500

F = {
    "regular": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "italic": "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
    "bolditalic": "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf",
    # NOTE: no "black" — macOS Arial Black lacks Vietnamese precomposed
    # glyphs (renders tofu □; verified via font_coverage.png). Heavy weight
    # is faked per-page with a same-color stroke on Arial Bold.
    "unicode": "/Library/Fonts/Arial Unicode.ttf",
}
for p in ("/System/Library/Fonts/Supplemental/Times New Roman.ttf",
          "/System/Library/Fonts/Supplemental/Times.ttf"):
    if os.path.exists(p):
        F["serif"] = p
        break
else:
    F["serif"] = F["italic"]

missing = [k for k, v in F.items() if not os.path.exists(v)]
if missing:
    raise SystemExit(f"missing fonts: {[F[k] for k in missing]}")


# ---------------------------------------------------------------- backgrounds
def grad_bg(top=(14, 16, 22), bot=(34, 38, 52)):
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)))
    return img


def noisy_bg(seed=7):
    """Busy background: gradient + random art-like blobs + speckle noise."""
    random.seed(seed)
    base = grad_bg((18, 18, 24), (46, 44, 58))
    d = ImageDraw.Draw(base)
    for _ in range(14):
        x, y = random.randrange(W), random.randrange(H)
        r = random.randrange(40, 170)
        col = tuple(random.randrange(25, 115) for _ in range(3))
        d.ellipse([x - r, y - r, x + r, y + r], fill=col)
    noise = Image.effect_noise((W, H), 56).convert("L")
    noise = noise.point(lambda v: 40 + v // 3)
    return Image.blend(base, Image.merge("RGB", (noise, noise, noise)), 0.35)


# ---------------------------------------------------------------- rendering
def draw_page(page):
    bg = noisy_bg() if page.get("busy") else grad_bg()
    d = ImageDraw.Draw(bg)
    size = page["size"]
    font = ImageFont.truetype(F[page["font"]], size)
    # fit-guard: shrink the page font until every line fits inside the
    # margins (a clipped line would poison ground truth — engines can't
    # read text that was never rendered).
    max_w = (W - 80) if page.get("align") == "center" else (W - 120)
    sw = page.get("stroke", 0)
    if any(font.getlength(ln) + 2 * sw > max_w for ln in page["lines"]):
        while size > 10:
            size -= 2
            font = ImageFont.truetype(F[page["font"]], size)
            if all(font.getlength(ln) + 2 * sw <= max_w for ln in page["lines"]):
                break
        print(f"fit {page['id']}: size {page['size']} -> {size}")
    fill = tuple(page.get("fill", (250, 250, 250)))
    stroke = page.get("stroke", 0)
    stroke_fill = tuple(page.get("stroke_fill", (8, 8, 8)))
    shadow = page.get("shadow", False)
    align = page.get("align", "left")
    anchor = "ma" if align == "center" else "la"

    y = page.get("y0", 300)
    gap = int(size * 0.45)
    for i, line in enumerate(page["lines"]):
        x = W // 2 if align == "center" else 60
        if shadow:
            for off in (5, 4, 3, 2, 1):
                d.text((x + off, y + off), line, font=font, fill=(0, 0, 0),
                       anchor=anchor, stroke_width=stroke, stroke_fill=(0, 0, 0))
        d.text((x, y), line, font=font, fill=fill, anchor=anchor,
               stroke_width=stroke, stroke_fill=stroke_fill)
        bbox = d.textbbox((x, y), line, font=font, anchor=anchor,
                          stroke_width=stroke)
        y = bbox[3] + gap
        if i + 1 in page.get("block_break_after", []):
            y += gap * 3  # extra space between dialogue blocks
    return bg


# ---------------------------------------------------------------- corpus
PAGES = [
    # --- Vietnamese (nhattruyenqq-style dialogue lettering) ---
    dict(id="vi_01_regular", lang="vi-VT", style="regular",
         font="regular", size=54,
         lines=["Tôi sẽ không bao giờ bỏ cuộc.",
                "Dù cho có khó khăn đến đâu."]),
    dict(id="vi_02_bold_caps", lang="vi-VT", style="bold/allcaps",
         font="bold", size=62, stroke=2, stroke_fill=(250, 250, 250),
         lines=["ĐỦ RỒI!", "TA SẼ KHÔNG CHỊU THỪA NỮA!"]),
    dict(id="vi_03_italic_stylized", lang="vi-VT", style="bold-italic caps",
         font="bolditalic", size=50,
         lines=["CẢNH ĐẸP MÊ HỒN CHO ĐỜI TA,",
                "CHƠI VỜI BÊN NHỮNG NGƯỜI THÂN YÊU."]),
    dict(id="vi_04_small", lang="vi-VT", style="small font (26px/800px)",
         font="regular", size=26,
         lines=["Ừ, tao biết rồi.", "Mày đừng lo, tao tự lo được."]),
    dict(id="vi_05_outline_sfx", lang="vi-VT", style="outlined SFX",
         font="bold", size=80, align="center", fill=(255, 255, 255),
         stroke=5, stroke_fill=(10, 10, 10), y0=380,
         lines=["BỐP!", "RẦM!"]),
    dict(id="vi_06_diacritic_heavy", lang="vi-VT", style="diacritic-heavy",
         font="regular", size=46,
         lines=["Tôi ước gì được gặp lại những ngày xưa,",
                "nghĩa là phải chấp nhận tất cả những gì xảy ra.",
                "Đường ướt, giấy lộn, học phí cứ tăng mãi."]),
    dict(id="vi_07_low_contrast", lang="vi-VT", style="low contrast",
         font="regular", size=46, fill=(92, 92, 92),
         lines=["Con đường này dẫn đến đâu?",
                "Chẳng ai trả lời tôi cả."]),
    dict(id="vi_08_busy_bg", lang="vi-VT", style="text on busy background",
         font="bold", size=48, busy=True, stroke=3, stroke_fill=(0, 0, 0),
         lines=["Cẩn thận! Có chuyện gì đó rồi!",
                "Mau chạy đi, ngay bây giờ!"]),
    dict(id="vi_09_serif_italic", lang="vi-VT", style="serif italic",
         font="serif", size=50, fill=(235, 235, 225),
         lines=["Một thoáng ký ức trôi qua...",
                "như làn khói mỏng ban mai."]),
    dict(id="vi_10_drop_shadow", lang="vi-VT", style="drop shadow",
         font="bold", size=56, shadow=True,
         lines=["ĐẾN LÚC PHẢI QUYẾT ĐỊNH RỒI.",
                "KHÔNG CÒN LỰA CHỌN NỮA."]),
    dict(id="vi_11_sfx_mixed_en", lang="vi-VT", style="SFX mixed vi+en",
         font="bold", size=76, align="center", y0=380,
         stroke=3, stroke_fill=(255, 255, 255),
         lines=["VỤT! WHOOSH~", "ĐINH! PENG!"]),
    dict(id="vi_12_two_blocks", lang="vi-VT", style="two dialogue blocks",
         font="regular", size=46, block_break_after=[1], y0=260,
         lines=["Ở trên kia nhìn xuống,",
                "ta thấy cả thế giới.",
                "Còn ở dưới này,",
                "chỉ toàn là bóng tối."]),
    dict(id="vi_13_rare_chars", lang="vi-VT", style="quotes/isolated diacritics",
         font="regular", size=44,
         lines=["«Đường về» — câu chuyện của riêng ta.",
                "Đ ơ ấ ữ ợ nhỉ? Đúng vậy!"]),
    dict(id="vi_14_mixed_en_caps", lang="vi-VT", style="mixed en/vn caps",
         font="bold", size=52,
         lines=["STOP RIGHT THERE!", "ĐỪNG CÓ DI CHUYỂN!"]),

    # --- Korean (future sources; ko-KR request) ---
    dict(id="ko_01_regular", lang="ko-KR", style="regular",
         font="unicode", size=46,
         lines=["안녕하세요, 오늘 날씨가 정말 좋네요!",
                "너희들은 어디로 가고 있어요?"]),
    dict(id="ko_02_bold", lang="ko-KR", style="bold (stroke-simulated)",
         font="unicode", size=52, stroke=2, stroke_fill=(255, 255, 255),
         lines=["이제 더 이상 참을 수 없다!",
                "준비됐어? 다 같이 가자!"]),
    dict(id="ko_03_small", lang="ko-KR", style="small font (24px)",
         font="unicode", size=24,
         lines=["조금만 더 가면 다 왔어.", "힘내자, 곧 도착해."]),
    dict(id="ko_04_hanja_brackets", lang="ko-KR", style="hanja + brackets",
         font="unicode", size=44,
         lines=["春來秋去, 시간은 흐른다.",
                "「그래도 우리는 여기 있어」"]),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = []
    for p in PAGES:
        img = draw_page(p)
        fname = f"{p['id']}.png"
        img.save(os.path.join(OUT, fname))
        manifest.append(dict(
            id=p["id"], file=f"corpus/{fname}", lang=p["lang"],
            style=p["style"], text="\n".join(p["lines"]),
        ))
    with open(os.path.join(HERE, "manifest.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print(f"wrote {len(manifest)} pages -> {OUT}")
    print(f"manifest -> {os.path.join(HERE, 'manifest.json')}")


if __name__ == "__main__":
    main()
