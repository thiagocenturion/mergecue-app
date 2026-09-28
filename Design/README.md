# MergeCue design assets

Everything in this folder and the files derived from it are produced by one reproducible, Pillow-only pipeline.
`Design/MergeCue-AppIcon.png` is the approved app icon (PLAN §1) and is used as-is: it is resized and cleaned,
never redrawn or recoloured.

| File | Role |
| --- | --- |
| `Design/MergeCue-AppIcon.png` | Source of truth for the app icon (1254×1254 RGBA, untagged sRGB). Do not edit. |
| `Design/menubar/MenuBar-{light,dark}[-dot][@2x].png` | **Owner-supplied menu bar icons — the shipped ones.** Source of truth; never generated or overwritten by a script. |
| `Design/menubar-glyph.svg`, `Design/menubar-glyph-alert.svg` | Earlier monochrome template glyph (reference only, no longer shipped). |
| `scripts/make-icons.py` | Entry point: app icon sizes, asset catalog JSON, verification, contact sheet; then runs `menubar_glyph.py`. |
| `scripts/menubar_glyph.py` | Renders the reference SVG glyph preview and **verifies** the owner menu bar icons (see below). |
| `App/Assets.xcassets/` | `AppIcon.appiconset` (mac 16–512 @1x/@2x), `AccentColor.colorset`, `MenuBarIcon.imageset`, `MenuBarIconAlert.imageset` (owner PNGs, `original` rendering). |
| `Sources/MergeCueUI/Resources/MenuBar-*.png` | Verbatim copies of `Design/menubar/` for `Bundle.module` in SwiftPM builds. |
| `docs/evidence/icon-contact-sheet.png` | Every icon size at 1:1 on light and dark, magnified small sizes, edge zooms. |
| `docs/evidence/menubar-glyph-preview.png` | Glyph at actual size in light and dark menu-bar-like strips (1x and 2x), plus magnified pixels. |
| `docs/evidence/icon-verification.json` | Machine-readable alpha stats and per-size check results from the last run. |

## Regenerate / verify

```sh
python3 scripts/make-icons.py          # rewrite every asset and evidence file, run all checks (exit 1 on failure)
python3 scripts/make-icons.py --check  # verify committed files only: checks + byte-for-byte match with the pipeline
```

Needs only Python 3 and Pillow (tested with the system Python 3.9.6 and Pillow 11.3.0). Output is deterministic:
two consecutive runs produced identical SHA-256 sums for all generated files.

**Menu bar icons are preserved.** Neither script writes `MenuBarIcon*.imageset/*` or the `MenuBar-*.png` copies
in `Sources/MergeCueUI/Resources/`. Both modes check that every file in `Design/menubar/` is present and
byte-identical in its imageset (`-dot` → `MenuBarIconAlert`, otherwise `MenuBarIcon`) and in the UI resources, and
that the imageset's `Contents.json` references it. The full run only restores a copy that is **missing**; a copy
that differs is reported as `FAIL` and left alone. To change the menu bar icon, replace the PNGs in
`Design/menubar/` and copy them to both places by hand (or delete the old copies and run the script). No Xcode project is involved.
`xcodegen`'s `project.yml` should point the app target at `App/Assets.xcassets`, with `AppIcon` as the app icon and
`AccentColor` as the global accent colour.

## App icon

### What the source contains (measured)

- Silhouette (alpha ≥ 128) bounding box: `(76, 87)–(1178, 1167)` exclusive, so **1102 × 1080 px**. The body is 2 %
  wider than tall.
- Interior alpha is 251–254 (1,006,077 px at 253–254, only 732 px at 255). The body is slightly translucent, so a
  wallpaper would faintly show through it in the Dock.
- The edge is a clean ~2 px ramp (for example `1, 130, 237, 245` on the left edge) whose RGB matches the adjacent body
  colour. There is no white or black matte baked into the edge.
- Outside the body there is no real glow. What looked like one is sparse speckle noise with alpha ≤ 15 (14,440 px),
  including a smudge of marks above the top edge (alpha ≤ 9) and 973 px more than 12 px from the body. The visible
  "glow" is the rim light painted inside the body, and the pipeline leaves it untouched.

### Derivation (`scripts/make-icons.py`)

1. **Gate.** Keep pixels within 1 px (Chebyshev) of the alpha ≥ 128 silhouette and zero everything else. Every
   genuine anti-aliased edge pixel touches a ≥ 50 % pixel, so the whole edge ramp survives while the speckles and
   the smudge (all ≥ 2 px out) are removed.
2. **Alpha levels.** Map `a → min(255, round(a·255/240))`. Everything with a ≥ 240 (the whole interior) becomes
   fully opaque. The edge ramp keeps its shape with no step (130 → 138, 237 → 252).
3. **Apple macOS grid.** Build a 1024 × 1024 transparent canvas with an 824 × 824 body box. The silhouette bbox is
   scaled proportionally so its longer side is exactly 824 px (scale 0.747731), then centred. The resulting body box
   is `(100.00, 108.23)–(924.00, 915.77)`: 100 px side margins and about 108 px top/bottom, because the source is
   not square. The source→canvas mapping is exact (a sub-pixel `resize(box=…)`), and only 24 px around the body are
   resampled, so nothing can reach the margins or corners.
4. **LANCZOS on premultiplied float channels.** Colour is multiplied by alpha in 32-bit float, resampled, and then
   un-premultiplied. This avoids dark or light fringes and avoids 8-bit banding at low alpha. Pixels with alpha 0
   get RGB 0.
5. **Ringing guard.** LANCZOS rings on a hard silhouette: it leaves a faint detached ring outside and 251–254 just
   inside. The same mapping is also resampled with an area (BOX) filter. Where the true area coverage is 0 the
   alpha is forced to 0, and where it is 255 the alpha is forced to 255. The LANCZOS value is kept only on the
   partially covered edge band.
6. **Per-size outputs.** 16, 32, 64, 128, 256, 512 and 1024 px (ten slots) are downsampled from the 1024 master with
   the same guarded premultiplied LANCZOS. The 1024 px slot is the master itself. Sizes ≤ 32 px get a light
   `UnsharpMask(radius 0.8, 60 %, threshold 0)` on colour only. Before sharpening, the edge colour is bled into the
   neighbouring transparent pixels so the silhouette cannot create a halo, and alpha is never sharpened. The radius
   and amount were chosen from a side-by-side of none / 0.5·40 / 0.7·45 / 0.8·70 / 1.0·60.
7. PNGs are saved untagged like the source (actool tags them sRGB), with `optimize=True`.

No drop shadow was added, because the source has none and PLAN §1 asks for the actual file rather than a redesign.

### Alpha before and after

| Alpha bucket | Source (1254²) | After gate + levels (1254²) | 1024 master |
| --- | ---: | ---: | ---: |
| 0 | 412,749 | 426,750 | 407,435 |
| 1–15 | 14,440 | 425 | 168 |
| 16–127 | 3,339 | 3,081 | 2,059 |
| 128–239 | 3,368 | 2,366 | 1,988 |
| 240–252 | 131,811 | 1,074 | 349 |
| 253–254 | 1,006,077 | 200 | 30 |
| 255 | 732 | 1,138,620 | 636,547 |
| Interior alpha (12 % inset) min–max | 251–254 | 255–255 | 255–255 |
| Pixels with alpha > 0 more than 12 px outside the body | 973 | 0 | 0 |

The remaining 1–254 values are exclusively the anti-aliased edge band.

### Per-size verification (all PASS)

Checks: exact size and RGBA mode; transparent corner patches; fully opaque centre (middle quarter); no alpha > 0
beyond the expected body box plus a tolerance of max(1.5 px, 16 master px); alpha monotonic along every inward
scanline of the middle 40 % of each side (no detached ring); and the **fringe** metric. Fringe is how far an edge
pixel's straight colour (64 ≤ α < 255) lies outside the per-channel colour range of the artwork it was resampled
from. It must have p95 ≤ 16 and max ≤ 32 (8-bit levels). `--check` also requires each committed PNG to be
pixel-identical to a fresh pipeline run.

| File | px | Corners | Centre | Outside | Alpha dips | Edge px 1–254 | Fringe p95 / max |
| --- | ---: | :-: | :-: | ---: | ---: | ---: | ---: |
| icon_16x16.png | 16 | 0 | 255 | 0 | 0 | 44 | 0 / 0 |
| icon_16x16@2x.png, icon_32x32.png | 32 | 0 | 255 | 0 | 0 | 92 | 0 / 0 |
| icon_32x32@2x.png | 64 | 0 | 255 | 0 | 0 | 197 | 0 / 0 |
| icon_128x128.png | 128 | 0 | 255 | 0 | 0 | 384 | 8 / 23 |
| icon_128x128@2x.png, icon_256x256.png | 256 | 0 | 255 | 0 | 0 | 1,079 | 6 / 8 |
| icon_256x256@2x.png, icon_512x512.png | 512 | 0 | 255 | 0 | 0 | 2,184 | 0 / 1 |
| icon_512x512@2x.png | 1024 | 0 | 255 | 0 | 0 | 4,594 | 0 / 2 |

**Negative control for the halo metric.** A naive per-channel LANCZOS resize (no premultiplication) of the master
with a black matte, and again with a white matte, was scored at 16–512 px. 11 of the 12 cases fail, with fringe max
70–141 and alpha dips at 32 and 128 px. The only case that passes is the black matte at 16 px (p95 5, max 9), where
the body border is itself near-black and the error cannot be seen. The pipeline scores max ≤ 23 at every size.

**Asset catalog compile.** `xcrun actool` (Xcode 26.6, `--platform macosx --minimum-deployment-target 15.0
--app-icon AppIcon --accent-color AccentColor`) compiled `App/Assets.xcassets` with no warnings or errors. It emitted
`AppIcon.icns` and `Assets.car`, and the partial Info.plist had `CFBundleIconName = AppIcon` and
`NSAccentColorName = AccentColor`. `assetutil --info` lists the ten AppIcon renditions (16–1024 px, sRGB), both
AccentColor appearances, and all four menu bar renditions with `Template Mode: template`.

**Visual check.** `docs/evidence/icon-contact-sheet.png` was inspected at every size on light (#F2F2F7) and dark
(#1C1C1E) backgrounds, with 16/32/64 px magnified and ×2–×8 zooms of the 1024 master corner, the 128 px corner and
the 1024 master right edge. The edges are smooth and anti-aliased on both backgrounds with no light or dark halo.
The thin dark outline and the inner rim light are part of the source art. Sizes ≤ 32 px keep the M, the triangle
cut-out and the mint dot legible.

## Menu bar template glyph (reference only — superseded by the owner's icons in `Design/menubar/`)

The app now ships the owner-supplied coloured PNGs (light glyphs for dark menu bars and vice versa, with `-dot`
variants for the attention state); `MenuBarIcon` in MergeCueUI picks the variant from the status button's
appearance. The glyph below is kept as a design reference; its PNGs are rendered in memory for the preview only.


The glyph echoes the icon's folded "M" as a line drawing. The left half is the **play-triangle loop** (forward cue).
A diagonal from the triangle's apex rises to the top of a **vertical bar**, which gives the M. The **signal dot** sits
nested in the top-right fold, separated from the strokes by a gap, just as in the icon.

- Canvas 18 × 18 pt (1 SVG unit = 1 pt). Strokes are 1.5 pt with round caps and joins, which matches SF Symbols
  "regular" weight at menu bar size. This was checked next to `bell`, `play.circle`, `wifi` and
  `arrow.triangle.merge` rendered at 14 pt. A 2 pt version looked noticeably heavier than the system extras.
- The stems are centred on x = 2.75 and 13.75, so their edges land on whole pixels in the @2x render (crisp 3 px
  stems). At @1x each stem is one full pixel plus one half-covered pixel.
- Ink bounds are 2.0–17.1 × 0.94–15.5 pt (normal) and 2.0–17.3 × 0.69–15.5 pt (attention). The body is optically
  centred and the dot overhangs up and to the right like a badge.
- **States** (the template image is monochrome, so the state is carried by shape):
  - `MenuBarIcon` has an outline ring (outer r 1.85 pt, 1 pt stroke) with a 0.9 pt gap.
  - `MenuBarIconAlert` has a filled disc (r 2.1 pt) with a 0.9 pt gap. Everything else is identical: the build
    asserts that the two renders differ only inside the dot zone (diff bbox `(12,0)–(18,6)` px at 1x and
    `(25,1)–(35,12)` px at 2x).

### Rendering

This machine has no `rsvg-convert`, `cairosvg` or Inkscape, and `qlmanage`/`sips` thumbnails give neither exact
geometry nor guaranteed transparency. `scripts/menubar_glyph.py` therefore rasterises the SVG subset used by these
files exactly:

- Each element becomes polygons in 16×16-supersampled space and is filled with pixel-centre sampling.
- Round strokes are drawn as the union of segment quads and vertex discs.
- The gap is a luminance `<mask>`.
- Coverage is box-averaged down to 8-bit alpha, with RGB fixed to black.
- Unsupported SVG raises an error instead of rendering incorrectly.

Historically these were written to both imagesets as template PNGs; that output was removed when the owner's
icons replaced the glyph (see "Menu bar icons are preserved" above).

**Cross-check against AppKit.** Both SVGs were also rendered with `NSImage` (CoreSVG) at 288 px and compared with
this renderer at 288 px:

- Total coverage agrees within 0.13 % and the ink bounding boxes are identical.
- Outside the dot gap, the mean |Δalpha| is 0.02 (normal) and 0.05 (attention) levels. Only 4 and 15 pixels differ
  by more than 32 levels, all on anti-aliased edges.
- Inside the gap, CoreSVG rasterises the `<mask>` at the nominal 18 pt resolution and upsamples it, which produces a
  blocky gap edge. So **ship the PNGs, and do not put the SVG itself into the asset catalog**.

**Visual check.** `docs/evidence/menubar-glyph-preview.png` shows both states and a pressed highlight in light
(#ECECEE, black ink at 85 %) and dark (#262628, white ink) menu-bar strips, at 1x (18 px) and 2x (36 px), next to
12 pt text, plus ×12/×6 magnifications. Both states read clearly at 2x. At 1x the ring becomes a small open blob, but
it stays distinct from the filled attention dot.

### Shipped icon (MergeCueUI / app target)

`MenuBarIcon.image(showsDot:)` (MergeCueUI) loads `MenuBar-light*` / `MenuBar-dark*` from `Bundle.module` and picks
the variant for the status button's effective appearance at draw time; the Xcode target's asset catalog carries the
same PNGs in `MenuBarIcon.imageset` / `MenuBarIconAlert.imageset` (`template-rendering-intent: original`).

## Accent colour

`AccentColor.colorset` takes the cyan-to-blue midpoint of the icon's ribbon (samples: #14A3FC, #1F6DFB, #3985FB):

| Appearance | Colour | Contrast |
| --- | --- | --- |
| Any / light | `#0C7FDB` (hue 207°) | 4.1:1 against white text, 3.8:1 on #F6F6F6 |
| Dark | `#2491F5` | 5.1:1 on #1E1E1E, 3.3:1 against white text (Apple's dark system blue #0A84FF is 3.7:1) |

## Not done / follow-ups

- The asset is a classic `AppIcon.appiconset` (macOS 15 deployment target). A macOS 26 Icon Composer `.icon` (Liquid
  Glass layers) would need layered source art, which the approved flat PNG does not provide.
- `docs/PLAN.md` embeds `./MergeCue-AppIcon.png`, which resolves to `docs/MergeCue-AppIcon.png`. The file lives in
  `Design/`.
