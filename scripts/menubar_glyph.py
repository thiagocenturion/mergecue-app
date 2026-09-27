#!/usr/bin/env python3
"""Render the MergeCue menu bar template glyph from its SVG source (Python 3 + Pillow only).

Normally run through `python3 scripts/make-icons.py`; can also run alone: `python3 scripts/menubar_glyph.py [--check]`.

Why a tiny SVG renderer: this machine has no rsvg-convert/cairosvg/inkscape, and qlmanage/sips thumbnails do
not give exact pixel geometry or guaranteed transparency. The glyph SVGs deliberately use a small subset, which
is rasterised here exactly: every element becomes polygons in supersampled space (SS x SS samples per output
pixel, pixel-centre sampling, nonzero/evenodd fill), strokes with round caps/joins are the union of segment
quads and vertex discs (the exact definition of a round-joined stroke), masks are luminance masks, and the
supersampled coverage is box-averaged down (Image.reduce) to 8-bit alpha. Anything outside the subset raises.

Supported SVG subset
    <svg viewBox> (square, origin 0 0), <title>, <desc>, <defs>, <mask id> (userSpaceOnUse), <g> (may carry
    mask="url(#id)" and inherited paint attributes), <path d> with absolute/relative M L H V Z only, <circle>,
    <rect> (no rx/ry). Paint: fill/stroke = none or a colour (ink is ink: template images ignore colour; inside
    a mask the colour's luminance is used), stroke-width, stroke-linecap="round", stroke-linejoin="round",
    fill-rule nonzero|evenodd. No transforms, opacity, dashes or curves.

Outputs (all black RGB, alpha = coverage, i.e. template images)
    App/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon{,@2x}.png            (18 px / 36 px)
    App/Assets.xcassets/MenuBarIconAlert.imageset/MenuBarIconAlert{,@2x}.png
    Contents.json of both sets with "template-rendering-intent": "template"
    Sources/MergeCueUI/Resources/ copies of the four PNGs (loadable via Bundle.module; set isTemplate = true)
    docs/evidence/menubar-glyph-preview.png (actual size on light/dark menu-bar-like strips + magnified)
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import xml.etree.ElementTree as ET  # noqa: E402
from pathlib import Path  # noqa: E402

from PIL import Image, ImageChops, ImageDraw, ImageFont  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "Design"
XCASSETS = ROOT / "App" / "Assets.xcassets"
UI_RESOURCES = ROOT / "Sources" / "MergeCueUI" / "Resources"
EVIDENCE = ROOT / "docs" / "evidence"

SS = 16                  # supersamples per output pixel along each axis
POINT_SIZE = 18          # template image size in points
GLYPHS = {               # asset name -> SVG source
    "MenuBarIcon": DESIGN / "menubar-glyph.svg",
    "MenuBarIconAlert": DESIGN / "menubar-glyph-alert.svg",
}
MIN_EDGE_MARGIN_PT = 0.25  # ink must stay at least this far from the canvas edge (no clipping)

SVG_NS = "{http://www.w3.org/2000/svg}"
INHERITED = ("fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "fill-rule")
UNSUPPORTED_ATTRS = ("transform", "opacity", "fill-opacity", "stroke-opacity", "stroke-dasharray", "style",
                     "clip-path", "filter")


class SVGSubsetError(ValueError):
    pass


# ----------------------------------------------------------------------------------------------------------------
# Rasteriser (operates on a bytearray of n x n supersamples)
# ----------------------------------------------------------------------------------------------------------------

class Layer:
    def __init__(self, n, value=0):
        self.n = n
        self.buf = bytearray([value]) * (n * n)

    def image(self):
        return Image.frombytes("L", (self.n, self.n), bytes(self.buf))

    @classmethod
    def from_image(cls, img):
        layer = cls(img.width)
        layer.buf = bytearray(img.tobytes())
        return layer

    def fill_polygons(self, polygons, value, evenodd=False):
        """Scanline fill sampling pixel centres; polygons are closed lists of (x, y) in supersample units."""
        edges = []
        for poly in polygons:
            for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
                if y0 == y1:
                    continue
                direction = 1 if y1 > y0 else -1
                if y0 > y1:
                    x0, y0, x1, y1 = x1, y1, x0, y0
                edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0), direction))
        if not edges:
            return
        n = self.n
        top = max(0, math.floor(min(e[0] for e in edges) - 0.5))
        bottom = min(n, math.ceil(max(e[1] for e in edges) + 0.5))
        fill = bytes([value])
        for row in range(top, bottom):
            yc = row + 0.5
            xs = sorted((x0 + (yc - y0) * k, d) for y0, y1, x0, k, d in edges if y0 <= yc < y1)
            winding, start = 0, 0.0
            for x, d in xs:
                before = winding
                winding = winding + 1 if evenodd else winding + d
                inside_before = (before % 2 == 1) if evenodd else before != 0
                inside_after = (winding % 2 == 1) if evenodd else winding != 0
                if not inside_before and inside_after:
                    start = x
                elif inside_before and not inside_after:
                    a = max(0, math.ceil(start - 0.5))
                    b = min(n, math.ceil(x - 0.5))
                    if b > a:
                        self.buf[row * n + a: row * n + b] = fill * (b - a)


def circle_polygon(cx, cy, r):
    segments = max(64, math.ceil(2 * math.pi * r))  # chord error < r * (1 - cos(pi / n)) ~ 0.005 samples
    return [(cx + r * math.cos(2 * math.pi * i / segments), cy + r * math.sin(2 * math.pi * i / segments))
            for i in range(segments)]


def stroke_primitives(points, closed, width):
    """Round-cap/round-join stroke of a polyline = segment quads + a disc at every vertex."""
    half = width / 2
    prims = [circle_polygon(x, y, half) for x, y in points]
    pairs = list(zip(points, points[1:]))
    if closed and len(points) > 2:
        pairs.append((points[-1], points[0]))
    for (x0, y0), (x1, y1) in pairs:
        length = math.hypot(x1 - x0, y1 - y0)
        if length == 0:
            continue
        nx, ny = -(y1 - y0) / length * half, (x1 - x0) / length * half
        prims.append([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)])
    return prims


# ----------------------------------------------------------------------------------------------------------------
# SVG subset interpreter
# ----------------------------------------------------------------------------------------------------------------

def parse_path(d):
    """Return [(points, closed)] for a path using only M/L/H/V/Z (absolute or relative)."""
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", d)
    subpaths, points, closed = [], [], False
    x = y = 0.0
    cmd, i = None, 0

    def num():
        nonlocal i
        if i >= len(tokens) or re.match(r"[A-Za-z]", tokens[i]):
            raise SVGSubsetError(f"path data ended early: {d!r}")
        i += 1
        return float(tokens[i - 1])

    while i < len(tokens):
        if re.match(r"[A-Za-z]", tokens[i]):
            cmd = tokens[i]
            i += 1
        elif cmd is None:
            raise SVGSubsetError(f"path data must start with a command: {d!r}")
        if cmd in "Zz":
            if points:
                subpaths.append((points, True))
                x, y = points[0]
            points, closed = [], False
            continue
        if cmd in "Mm":
            if points:
                subpaths.append((points, closed))
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if cmd == "m" and (points or subpaths) else (nx, ny)
            points = [(x, y)]
            cmd = "l" if cmd == "m" else "L"  # subsequent pairs are implicit line-tos
            continue
        if not points:  # drawing after Z starts a new subpath at the current point
            points = [(x, y)]
        if cmd in "Ll":
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if cmd == "l" else (nx, ny)
            points.append((x, y))
        elif cmd in "Hh":
            v = num()
            x = x + v if cmd == "h" else v
            points.append((x, y))
        elif cmd in "Vv":
            v = num()
            y = y + v if cmd == "v" else v
            points.append((x, y))
        else:
            raise SVGSubsetError(f"unsupported path command {cmd!r} (only M L H V Z)")
    if points:
        subpaths.append((points, closed))
    return subpaths


def paint_value(paint, in_mask):
    """None for 'none'; otherwise the 0..255 value painted (ink = 255, masks use luminance)."""
    paint = paint.strip().lower()
    if paint == "none":
        return None
    named = {"black": "#000000", "white": "#ffffff", "currentcolor": "#000000"}
    paint = named.get(paint, paint)
    m = re.fullmatch(r"#([0-9a-f]{3}|[0-9a-f]{6})", paint)
    if not m:
        raise SVGSubsetError(f"unsupported paint {paint!r}")
    hexv = m.group(1)
    if len(hexv) == 3:
        hexv = "".join(c * 2 for c in hexv)
    r, g, b = (int(hexv[k:k + 2], 16) for k in (0, 2, 4))
    return round(0.2126 * r + 0.7152 * g + 0.0722 * b) if in_mask else 255


class Renderer:
    def __init__(self, svg_path, px):
        self.tree = ET.parse(svg_path)
        root = self.tree.getroot()
        if root.tag != SVG_NS + "svg":
            raise SVGSubsetError("root element must be <svg>")
        vb = [float(v) for v in root.get("viewBox", "").replace(",", " ").split()]
        if len(vb) != 4 or vb[0] != 0 or vb[1] != 0 or vb[2] != vb[3]:
            raise SVGSubsetError("viewBox must be square with origin 0 0")
        self.units = vb[2]
        self.n = px * SS
        self.k = self.n / self.units  # user unit -> supersample
        self.masks = {el.get("id"): el for el in root.iter(SVG_NS + "mask")}

    def render(self):
        return self._group(self.tree.getroot(), {"fill": "#000000", "stroke": "none", "stroke-width": "1",
                                                  "fill-rule": "nonzero"}, in_mask=False)

    def _style(self, el, inherited):
        for attr in UNSUPPORTED_ATTRS:
            if el.get(attr) is not None:
                raise SVGSubsetError(f"<{el.tag.replace(SVG_NS, '')}> uses unsupported attribute {attr!r}")
        style = dict(inherited)
        for attr in INHERITED:
            if el.get(attr) is not None:
                style[attr] = el.get(attr)
        return style

    def _group(self, el, inherited, in_mask):
        style = self._style(el, inherited)
        layer = Layer(self.n)
        for child in el:
            tag = child.tag.replace(SVG_NS, "")
            if tag in ("title", "desc", "defs", "mask"):
                continue
            if tag == "g":
                if in_mask:
                    raise SVGSubsetError("groups inside <mask> are not supported")
                sub = self._group(child, style, in_mask)
            elif tag in ("path", "circle", "rect"):
                sub = self._shape(child, tag, style, in_mask)
            else:
                raise SVGSubsetError(f"unsupported element <{tag}>")
            if in_mask:  # masks paint in document order (later shapes cover earlier ones)
                layer = self._paint_over(layer, sub)
            else:
                layer = Layer.from_image(ImageChops.lighter(layer.image(), sub.image()))
        mask_ref = el.get("mask")
        if mask_ref:
            m = re.fullmatch(r"url\(#([^)]+)\)", mask_ref.strip())
            if not m or m.group(1) not in self.masks:
                raise SVGSubsetError(f"unknown mask {mask_ref!r}")
            mask_el = self.masks[m.group(1)]
            region = [float(mask_el.get(a, "nan")) for a in ("x", "y", "width", "height")]
            if mask_el.get("maskUnits") != "userSpaceOnUse" or region[:2] != [0, 0] or \
                    region[2] < self.units or region[3] < self.units:
                raise SVGSubsetError("masks must use maskUnits=\"userSpaceOnUse\" and cover the whole viewBox")
            mask = self._group(mask_el, {"fill": "#000000", "stroke": "none", "stroke-width": "1",
                                         "fill-rule": "nonzero"}, in_mask=True)
            layer = Layer.from_image(ImageChops.multiply(layer.image(), mask.image()))
        return layer

    @staticmethod
    def _paint_over(base, top):
        """Composite `top` over `base` where top has paint (top.coverage mask stored in top.painted)."""
        painted = getattr(top, "painted", None)
        if painted is None:
            return base
        return Layer.from_image(Image.composite(top.image(), base.image(), painted.image()))

    def _shape(self, el, tag, style, in_mask):
        style = self._style(el, style)
        k = self.k
        fill = paint_value(style["fill"], in_mask)
        stroke = paint_value(style["stroke"], in_mask)
        width = float(style["stroke-width"]) * k
        if tag == "path" and stroke is not None and (style.get("stroke-linecap", "butt") != "round"
                                                     or style.get("stroke-linejoin", "miter") != "round"):
            raise SVGSubsetError("path strokes must use round caps and joins")  # circles have neither
        layer, painted = Layer(self.n), Layer(self.n)
        evenodd = style.get("fill-rule", "nonzero") == "evenodd"
        if tag == "circle":
            cx, cy, r = (float(el.get(a)) * k for a in ("cx", "cy", "r"))
            if fill is not None:
                for target, v in ((layer, fill), (painted, 255)):
                    target.fill_polygons([circle_polygon(cx, cy, r)], v)
            if stroke is not None:
                ring = Layer(self.n)
                ring.fill_polygons([circle_polygon(cx, cy, r + width / 2)], 255)
                if r - width / 2 > 0:
                    ring.fill_polygons([circle_polygon(cx, cy, r - width / 2)], 0)
                layer = Layer.from_image(Image.composite(Image.new("L", (self.n, self.n), stroke),
                                                         layer.image(), ring.image()))
                painted = Layer.from_image(ImageChops.lighter(painted.image(), ring.image()))
        elif tag == "rect":
            if el.get("rx") or el.get("ry"):
                raise SVGSubsetError("rounded rects are not supported")
            x, y, w, h = (float(el.get(a, "0")) * k for a in ("x", "y", "width", "height"))
            poly = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
            if fill is not None:
                layer.fill_polygons([poly], fill)
                painted.fill_polygons([poly], 255)
            if stroke is not None:
                raise SVGSubsetError("stroked rects are not supported")
        else:
            subpaths = [([(px * k, py * k) for px, py in pts], closed) for pts, closed in parse_path(el.get("d", ""))]
            if fill is not None:
                closed_polys = [pts for pts, _ in subpaths if len(pts) > 2]
                layer.fill_polygons(closed_polys, fill, evenodd)
                painted.fill_polygons(closed_polys, 255, evenodd)
            if stroke is not None:
                for pts, closed in subpaths:
                    for prim in stroke_primitives(pts, closed, width):
                        layer.fill_polygons([prim], stroke)
                        painted.fill_polygons([prim], 255)
        layer.painted = painted
        return layer


def render_svg(svg_path, px):
    """Return (RGBA template image, ink bbox in points or None)."""
    coverage = Renderer(svg_path, px).render().image()
    bbox = coverage.getbbox()
    alpha = coverage.reduce(SS)
    black = Image.new("L", alpha.size, 0)
    img = Image.merge("RGBA", (black, black, black, alpha))
    ink = tuple(v / SS * POINT_SIZE / px for v in bbox) if bbox else None
    return img, ink


# ----------------------------------------------------------------------------------------------------------------
# Outputs, verification and preview
# ----------------------------------------------------------------------------------------------------------------

def write_imageset(name, images):
    folder = XCASSETS / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    for scale, img in images.items():
        img.save(folder / f"{name}{'' if scale == 1 else '@2x'}.png", optimize=True)
    contents = {
        "images": [{"filename": f"{name}{'' if s == 1 else '@2x'}.png", "idiom": "universal", "scale": f"{s}x"}
                   for s in sorted(images)],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    text = json.dumps(contents, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"
    (folder / "Contents.json").write_text(text, encoding="utf-8")
    UI_RESOURCES.mkdir(parents=True, exist_ok=True)
    for scale in images:
        fname = f"{name}{'' if scale == 1 else '@2x'}.png"
        shutil.copyfile(folder / fname, UI_RESOURCES / fname)


def verify_glyph(name, scale, img, ink, expected):
    px = POINT_SIZE * scale
    r, g, b, a = img.split()
    checks = {
        "size_ok": img.size == (px, px),
        "mode_ok": img.mode == "RGBA",
        "rgb_all_black": all(ch.getextrema() == (0, 0) for ch in (r, g, b)),
        "has_ink": a.getbbox() is not None,
        "ink_bbox_pt": [round(v, 3) for v in ink] if ink else None,
        "no_clipping": bool(ink) and min(ink[0], ink[1], POINT_SIZE - ink[2], POINT_SIZE - ink[3])
        >= MIN_EDGE_MARGIN_PT,
        "opaque_pixels": a.histogram()[255],
        "matches_svg_render": ImageChops.difference(img, expected).getbbox() is None,
    }
    checks["pass"] = all(v for k, v in checks.items() if k not in ("ink_bbox_pt", "opaque_pixels"))
    return checks


def _font(size):
    try:
        return ImageFont.load_default(size=size)
    except (TypeError, OSError):
        return ImageFont.load_default()


def _tint(glyph, rgba):
    """Template rendering: alpha is the shape, colour comes from the menu bar appearance."""
    layer = Image.new("RGBA", glyph.size, rgba[:3] + (0,))
    alpha = glyph.getchannel("A").point(lambda v: v * rgba[3] // 255)
    layer.putalpha(alpha)
    return layer


def preview(renders, path):
    """Menu-bar-like strips at 1x and 2x (actual pixels) plus nearest-neighbour magnification."""
    light = {"bar": (236, 236, 238), "ink": (0, 0, 0, 216), "hl": (0, 0, 0, 26), "text": (0, 0, 0)}
    dark = {"bar": (38, 38, 40), "ink": (255, 255, 255, 255), "hl": (255, 255, 255, 46), "text": (255, 255, 255)}
    W, H = 1500, 830
    sheet = Image.new("RGB", (W, H), (96, 96, 100))
    d = ImageDraw.Draw(sheet)
    d.text((20, 14), "MergeCue menu bar template glyph: normal and attention states at actual size, tinted like "
                     "macOS menu bars (light / dark), plus magnified pixels", fill=(255, 255, 255), font=_font(20))
    y = 56
    for scale in (1, 2):
        bar_h = 24 * scale
        for theme_name, theme in (("light", light), ("dark", dark)):
            bar = Image.new("RGBA", (W - 40, bar_h), theme["bar"] + (255,))
            bd = ImageDraw.Draw(bar)
            x = 20 * scale
            for label, name, pressed in (("normal", "MenuBarIcon", False), ("attention", "MenuBarIconAlert", False),
                                         ("pressed", "MenuBarIcon", True)):
                glyph = renders[(name, scale)]
                gy = (bar_h - glyph.height) // 2
                if pressed:
                    hl = Image.new("RGBA", bar.size, (0, 0, 0, 0))
                    ImageDraw.Draw(hl).rounded_rectangle(
                        [x - 4 * scale, 2 * scale, x + glyph.width + 4 * scale, bar_h - 2 * scale - 1],
                        radius=4 * scale, fill=theme["hl"])
                    bar.alpha_composite(hl)
                bar.alpha_composite(_tint(glyph, theme["ink"]), (x, gy))
                bd.text((x + glyph.width + 6 * scale, (bar_h - 13 * scale) // 2), label, fill=theme["text"],
                        font=_font(12 * scale))
                x += glyph.width + 90 * scale
            bd.text((W - 40 - 170 * scale, (bar_h - 13 * scale) // 2), "Sun 27 Sep 22:48", fill=theme["text"],
                    font=_font(12 * scale))
            sheet.paste(bar.convert("RGB"), (20, y))
            d.text((24, y + bar_h + 2), f"{theme_name} menu bar, {scale}x ({18 * scale} px glyph)",
                   fill=(230, 230, 230), font=_font(13))
            y += bar_h + 24
    y += 6
    x = 20
    for name in ("MenuBarIcon", "MenuBarIconAlert"):
        for scale, factor in ((1, 12), (2, 6)):
            glyph = renders[(name, scale)]
            for theme in (light, dark):
                tile = Image.new("RGBA", glyph.size, theme["bar"] + (255,))
                tile.alpha_composite(_tint(glyph, theme["ink"]))
                tile = tile.resize((glyph.width * factor, glyph.height * factor), Image.Resampling.NEAREST)
                sheet.paste(tile.convert("RGB"), (x, y))
                x += tile.width + 8
            d.text((x - 2 * (glyph.width * factor + 8), y + 216 + 4), f"{name} {scale}x (x{factor})",
                   fill=(255, 255, 255), font=_font(13))
            x += 14
        if x > W - 900:
            x = 20
            y += 250
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.crop((0, 0, W, min(H, y + 250))).save(path, optimize=True)


def main(check_only=False):
    ok = True
    renders = {}
    for name, svg in GLYPHS.items():
        images = {}
        for scale in (1, 2):
            img, ink = render_svg(svg, POINT_SIZE * scale)
            images[scale] = img
            renders[(name, scale)] = img
            renders[(name, scale, "ink")] = ink
        if not check_only:
            write_imageset(name, images)
        for scale, expected in images.items():
            fname = f"{name}{'' if scale == 1 else '@2x'}.png"
            for location in (XCASSETS / f"{name}.imageset" / fname, UI_RESOURCES / fname):
                on_disk = Image.open(location)
                on_disk.load()
                result = verify_glyph(name, scale, on_disk.convert("RGBA"), renders[(name, scale, "ink")], expected)
                result["template_intent"] = json.loads(
                    (XCASSETS / f"{name}.imageset" / "Contents.json").read_text(encoding="utf-8")
                ).get("properties", {}).get("template-rendering-intent") == "template"
                result["pass"] = result["pass"] and result["template_intent"] and on_disk.mode == "RGBA"
                ok &= result["pass"]
                print(f"{'PASS' if result['pass'] else 'FAIL'} {location.relative_to(ROOT)} "
                      f"{on_disk.size[0]}px ink={result['ink_bbox_pt']} opaque={result['opaque_pixels']}")
    # The two states must differ only around the signal dot.
    for scale in (1, 2):
        diff = ImageChops.difference(renders[("MenuBarIcon", scale)], renders[("MenuBarIconAlert", scale)]).getbbox()
        dot_zone = tuple(v * scale for v in (11.0, 0.0, 18.0, 7.0))
        within = diff is not None and diff[0] >= dot_zone[0] and diff[1] >= dot_zone[1] and \
            diff[2] <= dot_zone[2] and diff[3] <= dot_zone[3]
        ok &= within
        print(f"{'PASS' if within else 'FAIL'} states differ only near the dot at {scale}x: diff bbox {diff}")
    if not check_only:
        preview({k: v for k, v in renders.items() if len(k) == 2}, EVIDENCE / "menubar-glyph-preview.png")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main(check_only="--check" in sys.argv[1:]) else 1)
