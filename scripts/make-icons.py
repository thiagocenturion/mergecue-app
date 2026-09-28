#!/usr/bin/env python3
"""Reproducible MergeCue icon pipeline (Python 3 + Pillow only).

Usage:  python3 scripts/make-icons.py            # regenerate every asset + evidence, verify, exit 1 on failure
        python3 scripts/make-icons.py --check    # verify the committed outputs without rewriting them

Source of truth
    Design/MergeCue-AppIcon.png (1254x1254 RGBA, untagged sRGB). It is used as-is: no redraw, no recolouring.
    Measured facts that drive the choices below:
      * body silhouette (alpha >= 128) bbox = (76, 87)-(1178, 1167) exclusive -> 1102 x 1080 px (not square);
      * interior alpha is 251..254 (mostly 253) -> the body is very slightly translucent;
      * the silhouette edge is a clean ~2 px ramp whose RGB matches the adjacent body (no baked fringe);
      * outside the body there is only sparse speckle noise with alpha <= 15 (including a smudge above the top
        edge) -- the visible "glow" is the rim light painted *inside* the body, which is preserved untouched.

Derivation of the 1024 px master (Apple macOS icon grid: 1024 canvas, 824 x 824 body box, 100 px margin)
    1. Gate: keep source pixels within GATE_RADIUS px (Chebyshev) of the alpha >= 128 silhouette; zero the rest.
       Every genuinely anti-aliased edge pixel touches a >= 50 % pixel, so this keeps the full edge ramp and
       removes the speckle noise/smudge (which sits >= 2 px outside the edge).
    2. Levels on alpha: a' = min(255, round(a * 255 / OPAQUE_FROM)). Every pixel with a >= 240 (the whole
       interior) becomes fully opaque; the edge ramp keeps its shape (e.g. 130 -> 138) with no step.
    3. Scale the silhouette bbox proportionally (LANCZOS) so its longer side is exactly 824 px, centred on the
       canvas (824 x 808 -> margins 100 px horizontal, ~108 px vertical). The source-to-canvas mapping is exact
       (sub-pixel resize box), and only PAD px around the body are resampled, so nothing can reach the corners.
    4. Resampling happens on premultiplied float channels (no dark/light fringe, no 8-bit banding at low alpha);
       colour is un-premultiplied afterwards and pixels with alpha 0 get RGB 0.
    5. Ringing guard: LANCZOS rings on the hard silhouette (faint detached ring outside, 251..254 just inside).
       The same mapping is also resampled with an area (BOX) filter; where the true area coverage is 0 the
       output alpha is forced to 0, where it is 255 alpha is forced to 255. The LANCZOS value is kept only on
       the partially covered edge band, so edges stay crisp and the body stays fully opaque.
Per-size outputs
    Every size is downsampled from the 1024 master with the same guarded premultiplied LANCZOS filter. Sizes
    <= 32 px get a light unsharp mask (UNSHARP) on colour only, after bleeding edge colour into transparent
    pixels so the silhouette itself cannot produce a halo; alpha is never sharpened.
    Files: App/Assets.xcassets/AppIcon.appiconset/icon_<pt>x<pt>[@2x].png (mac idiom 16/32/128/256/512 @1x/@2x).
    PNGs are written untagged like the source (actool treats them as sRGB), deterministic (same bytes every run).
Verification (per output; results in docs/evidence/icon-verification.json and Design/README.md)
    size & RGBA mode; transparent corners; fully opaque centre; nothing outside the expected body box + tolerance;
    alpha monotonic along every inward scanline of the middle 40% (no detached ring); fringe = how far an edge
    pixel's straight colour (64 <= alpha < 255) lies outside the colour range of the artwork it was resampled
    from (a matte/premultiplication halo lands outside it): p95 <= FRINGE_P95_MAX and max <= FRINGE_ABS_MAX.
    Negative control (Design/README.md): a naive per-channel LANCZOS resize with a black or white matte scores
    fringe max 70..141 at 64..512 px and fails; this pipeline scores max <= 23.
    Visual evidence: docs/evidence/icon-contact-sheet.png (all sizes on light and dark, magnified small sizes,
    edge zooms). scripts/menubar_glyph.py (invoked from here) renders the reference SVG glyph preview and verifies the
    owner-supplied menu bar icons (Design/menubar/ -> MenuBarIcon*.imageset, UI resources) without overwriting them.
"""
import sys

sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__

import argparse  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
from pathlib import Path  # noqa: E402

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageMath  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design" / "MergeCue-AppIcon.png"
XCASSETS = ROOT / "App" / "Assets.xcassets"
APPICONSET = XCASSETS / "AppIcon.appiconset"
EVIDENCE = ROOT / "docs" / "evidence"

CANVAS = 1024            # master canvas (px)
BODY = 824               # Apple grid body box (px); the longer side of the body is fitted to this
BODY_ALPHA = 128         # silhouette threshold used to measure the body
GATE_RADIUS = 1          # source px kept outside the silhouette (the anti-aliased ramp is ~2 px wide)
OPAQUE_FROM = 240        # alpha levels white point: a >= 240 -> 255
PAD = 24                 # master px resampled around the body box
SRC_PAD = 64             # transparent padding added around the source before resampling
SHARPEN_MAX_PX = 32      # sizes that receive the unsharp mask
UNSHARP = ImageFilter.UnsharpMask(radius=0.8, percent=60, threshold=0)
FRINGE_P95_MAX = 16      # fringe (see Verification) accepted as "no halo": 95th percentile ...
FRINGE_ABS_MAX = 32      # ... and worst pixel (8-bit levels, max over R/G/B)
MONOTONE_TOL = 3         # alpha may dip by at most this much along an inward scanline

# (point size, scale) for the macOS AppIcon set
ICON_SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

ACCENT_LIGHT = (0x0C, 0x7F, 0xDB)   # #0C7FDB, 4.1:1 with white text; hue 207 deg (icon cyan->blue midpoint)
ACCENT_DARK = (0x24, 0x91, 0xF5)    # #2491F5, 5.1:1 on #1E1E1E; brighter for dark appearance


# ----------------------------------------------------------------------------------------------------------------
# Premultiplied float resampling
# ----------------------------------------------------------------------------------------------------------------

def _premultiplied_bands(img):
    r, g, b, a = (band.convert("F") for band in img.split())
    premul = [ImageMath.lambda_eval(lambda e: e["c"] * e["a"] / 255.0, c=c, a=a) for c in (r, g, b)]
    return premul + [a]


def _to_rgba8(r, g, b, a):
    """Un-premultiply float bands, round, clamp; RGB of fully transparent pixels becomes 0."""
    a8 = ImageMath.lambda_eval(lambda e: e["min"](e["max"](e["a"], 0.0), 255.0) + 0.5, a=a).convert("L")
    af = a8.convert("F")
    out = []
    for c in (r, g, b):
        # division by zero yields 0 in ImageMath, which is exactly what alpha-0 pixels need
        straight = ImageMath.lambda_eval(lambda e: e["c"] * 255.0 / e["a"], c=c, a=af)
        straight = ImageMath.lambda_eval(lambda e: e["min"](e["max"](e["s"], 0.0), 255.0) + 0.5, s=straight)
        out.append(straight.convert("L"))
    return Image.merge("RGBA", out + [a8])


def resize_premultiplied(img, size, box=None):
    """Premultiplied float LANCZOS resize with the area-coverage ringing guard (header step 5)."""
    bands = _premultiplied_bands(img)
    resized = _to_rgba8(*(band.resize(size, Image.Resampling.LANCZOS, box=box) for band in bands))
    coverage = img.getchannel("A").resize(size, Image.Resampling.BOX, box=box)
    covered = coverage.point(lambda v: 255 if v > 0 else 0)
    full = coverage.point(lambda v: 255 if v == 255 else 0)
    r, g, b, a = resized.split()
    a = ImageChops.lighter(ImageChops.darker(a, covered), full)
    return zero_transparent_rgb(Image.merge("RGBA", (r, g, b, a)))


def zero_transparent_rgb(img):
    r, g, b, a = img.split()
    visible = a.point(lambda v: 255 if v > 0 else 0)
    return Image.merge("RGBA", [ImageChops.darker(c, visible) for c in (r, g, b)] + [a])


# ----------------------------------------------------------------------------------------------------------------
# Statistics
# ----------------------------------------------------------------------------------------------------------------

ALPHA_BUCKETS = [(0, 0), (1, 15), (16, 127), (128, 239), (240, 252), (253, 254), (255, 255)]


def alpha_stats(img, body_box=None):
    a = img.getchannel("A")
    hist = a.histogram()
    stats = {
        "size": list(img.size),
        "histogram": {f"{lo}-{hi}" if lo != hi else str(lo): sum(hist[lo:hi + 1]) for lo, hi in ALPHA_BUCKETS},
        "bbox_alpha_gt0": list(a.getbbox() or ()),
        "bbox_alpha_ge128": list(a.point(lambda v: 255 if v >= 128 else 0).getbbox() or ()),
    }
    if body_box is not None:
        # interior = body box inset by 12% (clear of the rounded corners and the edge ramp)
        x0, y0, x1, y1 = body_box
        ix, iy = (x1 - x0) * 0.12, (y1 - y0) * 0.12
        interior = a.crop((round(x0 + ix), round(y0 + iy), round(x1 - ix), round(y1 - iy)))
        stats["interior_alpha_min_max"] = list(interior.getextrema())
        ring = a.copy()
        ImageDraw.Draw(ring).rectangle([x0 - 12, y0 - 12, x1 + 11, y1 + 11], fill=0)
        stats["faint_pixels_beyond_12px"] = sum(ring.histogram()[1:])
    return stats


# ----------------------------------------------------------------------------------------------------------------
# Master derivation
# ----------------------------------------------------------------------------------------------------------------

def body_bbox(img):
    box = img.getchannel("A").point(lambda v: 255 if v >= BODY_ALPHA else 0).getbbox()
    if box is None:
        raise SystemExit("source has no opaque body")
    return box


def clean_source(src):
    """Gate speckle noise far from the silhouette, then apply the alpha levels (see header)."""
    alpha = src.getchannel("A")
    body = alpha.point(lambda v: 255 if v >= BODY_ALPHA else 0)
    keep = body.filter(ImageFilter.MaxFilter(2 * GATE_RADIUS + 1))
    gated = ImageChops.darker(alpha, keep)
    levelled = gated.point(lambda v: min(255, int(v * 255 / OPAQUE_FROM + 0.5)))
    r, g, b, _ = src.split()
    return zero_transparent_rgb(Image.merge("RGBA", (r, g, b, levelled)))


def master_geometry(bbox):
    bx0, by0, bx1, by1 = bbox
    bw, bh = bx1 - bx0, by1 - by0
    scale = BODY / max(bw, bh)
    tw, th = bw * scale, bh * scale
    tx0, ty0 = (CANVAS - tw) / 2, (CANVAS - th) / 2
    return {"scale": scale, "target": (tx0, ty0, tx0 + tw, ty0 + th)}


def make_master(cleaned, bbox):
    geo = master_geometry(bbox)
    s = geo["scale"]
    tx0, ty0, tx1, ty1 = geo["target"]
    ox0, oy0 = math.floor(tx0 - PAD), math.floor(ty0 - PAD)
    ox1, oy1 = math.ceil(tx1 + PAD), math.ceil(ty1 + PAD)
    bx0, by0 = bbox[0], bbox[1]
    src_box = (bx0 + (ox0 - tx0) / s + SRC_PAD, by0 + (oy0 - ty0) / s + SRC_PAD,
               bx0 + (ox1 - tx0) / s + SRC_PAD, by0 + (oy1 - ty0) / s + SRC_PAD)
    padded = Image.new("RGBA", (cleaned.width + 2 * SRC_PAD, cleaned.height + 2 * SRC_PAD), (0, 0, 0, 0))
    padded.paste(cleaned, (SRC_PAD, SRC_PAD))
    region = resize_premultiplied(padded, (ox1 - ox0, oy1 - oy0), box=src_box)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(region, (ox0, oy0))
    return canvas, geo


def bleed_rgb(img, passes=2):
    """Copy edge colour into neighbouring alpha-0 pixels so colour filters see no silhouette contrast."""
    w, h = img.size
    data = list(img.getdata())
    rgb = [p[:3] for p in data]
    weight = [p[3] for p in data]
    for _ in range(passes):
        new_rgb, new_weight = rgb[:], weight[:]
        for y in range(h):
            for x in range(w):
                i = y * w + x
                if weight[i]:
                    continue
                acc, total = [0.0, 0.0, 0.0], 0.0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if (dx or dy) and 0 <= nx < w and 0 <= ny < h:
                            j = ny * w + nx
                            if weight[j]:
                                for k in range(3):
                                    acc[k] += rgb[j][k] * weight[j]
                                total += weight[j]
                if total:
                    new_rgb[i] = tuple(int(v / total + 0.5) for v in acc)
                    new_weight[i] = 1
        rgb, weight = new_rgb, new_weight
    out = Image.new("RGB", img.size)
    out.putdata(rgb)
    return out


def sharpen_small(img):
    sharpened = bleed_rgb(img).filter(UNSHARP)
    r, g, b = sharpened.split()
    return zero_transparent_rgb(Image.merge("RGBA", (r, g, b, img.getchannel("A"))))


def derive_size(master, px):
    img = master if px == CANVAS else resize_premultiplied(master, (px, px))
    return sharpen_small(img) if px <= SHARPEN_MAX_PX else img


def slot_filename(pt, scale):
    return f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"


# ----------------------------------------------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------------------------------------------

def _scan_profiles(img):
    """Yield alpha values along inward scanlines of the middle 40% of each side."""
    w, h = img.size
    a = img.getchannel("A").load()
    lo, hi = int(w * 0.3), int(math.ceil(w * 0.7))
    for y in range(lo, hi):
        row = [a[x, y] for x in range(w)]
        yield row[: w // 2]
        yield row[::-1][: w // 2]
    for x in range(lo, hi):
        col = [a[x, y] for y in range(h)]
        yield col[: h // 2]
        yield col[::-1][: h // 2]


def _alpha_dips(img):
    dips = 0
    for profile in _scan_profiles(img):
        best = 0
        for v in profile:
            if v + MONOTONE_TOL < best:
                dips += 1
            best = max(best, v)
            if v == 255:
                break
    return dips


def _fringe_distances(img, reference, footprint):
    """Halo metric for every edge pixel (64 <= alpha < 255).

    A resampled edge pixel must be a blend of the artwork it was sampled from. `footprint(x, y)` returns the
    reference-image box that output pixel (x, y) was computed from (widened by one output pixel on each side);
    the distance is how far the pixel's straight colour lies outside the per-channel colour range of the visible
    (alpha > 0) reference pixels in that box. Mixing in the transparent matte (a premultiplication bug) or a baked
    white/black fringe lands outside that range; correct filtering stays inside it (LANCZOS/unsharp overshoot
    only by a few levels).
    """
    w, h = img.size
    px = img.load()
    ref = reference.load()
    rw, rh = reference.size
    out = []
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            if not 64 <= p[3] < 255:
                continue
            fx0, fy0, fx1, fy1 = footprint(x, y)
            lo, hi = [255, 255, 255], [0, 0, 0]
            for ry in range(max(0, math.floor(fy0)), min(rh, math.ceil(fy1))):
                for rx in range(max(0, math.floor(fx0)), min(rw, math.ceil(fx1))):
                    q = ref[rx, ry]
                    if q[3]:
                        for ch in range(3):
                            lo[ch] = min(lo[ch], q[ch])
                            hi[ch] = max(hi[ch], q[ch])
            out.append(max(max(lo[ch] - p[ch], p[ch] - hi[ch], 0) for ch in range(3)))
    return sorted(out)


def verify_icon(img, px, target_box, reference, footprint):
    a = img.getchannel("A")
    k = max(1, px // 16)
    corners = [(0, 0, k, k), (px - k, 0, px, k), (0, px - k, k, px), (px - k, px - k, px, px)]
    c = max(1, px // 4)
    c0 = (px - c) // 2
    f = px / CANVAS
    tol = max(1.5, 16 * f)
    x0, y0, x1, y1 = (v * f for v in target_box)
    outside = a.copy()
    ImageDraw.Draw(outside).rectangle(
        [math.floor(x0 - tol), math.floor(y0 - tol), math.ceil(x1 + tol) - 1, math.ceil(y1 + tol) - 1], fill=0)
    dips = _alpha_dips(img)
    fringe = _fringe_distances(img, reference, footprint)
    p95 = fringe[int(0.95 * (len(fringe) - 1))] if fringe else 0
    hist = a.histogram()
    partial = sum(hist[1:255])
    result = {
        "px": px,
        "size_ok": img.size == (px, px),
        "mode_ok": img.mode == "RGBA",
        "corners_transparent": all(a.crop(box).getextrema() == (0, 0) for box in corners),
        "center_opaque": a.crop((c0, c0, c0 + c, c0 + c)).getextrema() == (255, 255),
        "pixels_outside_body_tolerance": sum(outside.histogram()[1:]),
        "alpha_dips_on_inward_scanlines": dips,
        "edge_pixels_sampled": len(fringe),
        "fringe_p95": p95,
        "fringe_max": fringe[-1] if fringe else 0,
        "antialiased_edge_pixels": partial,
        "alpha_histogram": {"0": hist[0], "1-254": partial, "255": hist[255]},
    }
    result["pass"] = bool(result["size_ok"] and result["mode_ok"] and result["corners_transparent"]
                          and result["center_opaque"] and result["pixels_outside_body_tolerance"] == 0
                          and dips == 0 and p95 <= FRINGE_P95_MAX and result["fringe_max"] <= FRINGE_ABS_MAX
                          and partial > 0)
    return result


# ----------------------------------------------------------------------------------------------------------------
# Asset catalog
# ----------------------------------------------------------------------------------------------------------------

def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(obj, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"
    path.write_text(text, encoding="utf-8")


def catalog_info():
    return {"author": "xcode", "version": 1}


def _color(rgb):
    r, g, b = rgb
    return {"color-space": "srgb",
            "components": {"alpha": "1.000", "red": f"0x{r:02X}", "green": f"0x{g:02X}", "blue": f"0x{b:02X}"}}


def write_catalog_scaffold():
    write_json(XCASSETS / "Contents.json", {"info": catalog_info()})
    write_json(XCASSETS / "AccentColor.colorset" / "Contents.json", {
        "colors": [
            {"color": _color(ACCENT_LIGHT), "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "color": _color(ACCENT_DARK), "idiom": "universal"},
        ],
        "info": catalog_info(),
    })
    write_json(APPICONSET / "Contents.json", {
        "images": [{"filename": slot_filename(pt, sc), "idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}"}
                   for pt, sc in ICON_SLOTS],
        "info": catalog_info(),
    })


# ----------------------------------------------------------------------------------------------------------------
# Contact sheet
# ----------------------------------------------------------------------------------------------------------------

LIGHT_BG = (242, 242, 247)
DARK_BG = (28, 28, 30)


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except (TypeError, OSError):  # Pillow without FreeType
        return ImageFont.load_default()


def _on(bg, img, scale=1):
    if scale != 1:
        img = img.resize((img.width * scale, img.height * scale), Image.Resampling.NEAREST)
    tile = Image.new("RGBA", img.size, bg + (255,))
    tile.alpha_composite(img)
    return tile.convert("RGB")


def contact_sheet(outputs, path):
    """All unique pixel sizes at 1:1 on light and dark, small sizes magnified, and edge zooms."""
    by_px = {im.width: im for im in outputs.values()}
    master = by_px[CANVAS]
    W, band_h, zoom_h = 1920, 590, 300
    H = 64 + 2 * (band_h + 16) + 32 + zoom_h + 44
    sheet = Image.new("RGB", (W, H), (96, 96, 100))
    d = ImageDraw.Draw(sheet)
    title, small = font(22), font(14)
    d.text((24, 18), "MergeCue AppIcon.appiconset: every size at 1:1 on light and dark, small sizes magnified "
                     "(nearest neighbour), edge zooms. Generated by scripts/make-icons.py", fill=(255, 255, 255),
           font=title)
    y = 64
    for bg, name in ((LIGHT_BG, "light"), (DARK_BG, "dark")):
        fg = (0, 0, 0) if name == "light" else (255, 255, 255)
        sheet.paste(Image.new("RGB", (W - 32, band_h), bg), (16, y))
        d.text((32, y + 10), f"{name} background, 1:1 (1024 px master shown in the edge zooms below)",
               fill=fg, font=small)
        x, base = 32, y + 40 + 512
        for px in (16, 32, 64, 128, 256, 512):
            sheet.paste(_on(bg, by_px[px]), (x, base - px))
            d.text((x, base + 8), f"{px} px", fill=fg, font=small)
            x += px + 30
        mx = x + 10
        for px, factor in ((16, 12), (32, 6), (64, 3)):
            sheet.paste(_on(bg, by_px[px], factor), (mx, y + 40))
            d.text((mx, y + 40 + 192 + 8), f"{px} px x{factor}", fill=fg, font=small)
            mx += 192 + 24
        y += band_h + 16
    d.text((32, y + 6), "edge zooms (light | dark): 1024 master top-left corner x2, 128 px top-left corner x8, "
                        "1024 master right edge x6", fill=(255, 255, 255), font=small)
    y += 32
    zooms = [
        (master.crop((96, 104, 246, 254)), 2),
        (by_px[128].crop((10, 11, 40, 41)), 8),
        (master.crop((884, 492, 934, 542)), 6),
    ]
    x = 32
    for crop, factor in zooms:
        for bg in (LIGHT_BG, DARK_BG):
            tile = _on(bg, crop, factor)
            sheet.paste(tile, (x, y))
            x += tile.width + 12
        x += 24
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, optimize=True)


# ----------------------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------------------

def build(check_only):
    src = Image.open(SOURCE)
    src.load()
    if src.mode != "RGBA":
        raise SystemExit(f"expected RGBA source, got {src.mode}")
    bbox = body_bbox(src)
    cleaned = clean_source(src)
    master, geo = make_master(cleaned, bbox)
    report = {
        "source": {"file": str(SOURCE.relative_to(ROOT)), "silhouette_bbox": list(bbox),
                   **alpha_stats(src, bbox)},
        "cleaned_source": alpha_stats(cleaned, bbox),
        "master": {"scale": round(geo["scale"], 6), "body_box": [round(v, 2) for v in geo["target"]],
                   **alpha_stats(master, geo["target"])},
        "outputs": {},
    }
    s = geo["scale"]
    tx0, ty0 = geo["target"][0], geo["target"][1]

    def master_footprint(x, y):  # master pixel -> cleaned-source box
        return (bbox[0] + (x - 1 - tx0) / s, bbox[1] + (y - 1 - ty0) / s,
                bbox[0] + (x + 2 - tx0) / s, bbox[1] + (y + 2 - ty0) / s)

    outputs = {}
    for pt, sc in ICON_SLOTS:
        px = pt * sc
        name = slot_filename(pt, sc)
        path = APPICONSET / name
        expected = derive_size(master, px)
        if not check_only:
            path.parent.mkdir(parents=True, exist_ok=True)
            expected.save(path, optimize=True)
        img = Image.open(path)
        img.load()
        outputs[name] = img
        if px == CANVAS:
            reference, footprint = cleaned, master_footprint
        else:
            f = CANVAS / px
            reference = master
            footprint = (lambda f: lambda x, y: ((x - 1) * f, (y - 1) * f, (x + 2) * f, (y + 2) * f))(f)
        result = verify_icon(img, px, geo["target"], reference, footprint)
        result["matches_pipeline"] = img.mode == "RGBA" and ImageChops.difference(img, expected).getbbox() is None
        result["pass"] = result["pass"] and result["matches_pipeline"]
        report["outputs"][name] = result
    if not check_only:
        write_catalog_scaffold()
        contact_sheet(outputs, EVIDENCE / "icon-contact-sheet.png")
        write_json(EVIDENCE / "icon-verification.json", report)
    return report


def print_report(report):
    s, c, m = report["source"], report["cleaned_source"], report["master"]
    print(f"source   {s['size']} silhouette bbox {s['silhouette_bbox']} interior alpha {s['interior_alpha_min_max']}"
          f" faint px beyond 12px {s['faint_pixels_beyond_12px']}")
    print(f"cleaned  interior alpha {c['interior_alpha_min_max']} faint px beyond 12px {c['faint_pixels_beyond_12px']}")
    print(f"master   scale {m['scale']} body box {m['body_box']} interior alpha {m['interior_alpha_min_max']}")
    for label, st in (("source", s), ("cleaned", c), ("master", m)):
        print(f"  {label:8s} alpha histogram {st['histogram']}")
    ok = True
    for name, r in report["outputs"].items():
        ok &= r["pass"]
        print(f"{'PASS' if r['pass'] else 'FAIL'} {name:22s} {r['px']:>4}px corners={r['corners_transparent']} "
              f"centre={r['center_opaque']} outside={r['pixels_outside_body_tolerance']} "
              f"dips={r['alpha_dips_on_inward_scanlines']} fringe_p95={r['fringe_p95']} "
              f"max={r['fringe_max']} aa={r['antialiased_edge_pixels']}")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="verify committed outputs without rewriting them")
    parser.add_argument("--skip-glyph", action="store_true", help="skip the menu bar glyph preview and owner icon checks")
    args = parser.parse_args()
    report = build(args.check)
    ok = print_report(report)
    if not args.skip_glyph:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import menubar_glyph  # noqa: E402  (sibling module)
        ok &= menubar_glyph.main(check_only=args.check)
    print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
