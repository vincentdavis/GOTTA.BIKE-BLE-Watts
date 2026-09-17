#!/usr/bin/env python3
"""Draw the launcher-icon sources and Play Store graphics for GOTTA.BIKE: BLE Watts.

PLACEHOLDER ARTWORK
-------------------
GOTTA.BIKE's real logo and palette were not available when this was written,
so the mark (a lightning bolt between two pairs of broadcast arcs) and the
colours in the "Brand" section are stand-ins. To rebrand, either:

* tweak the placeholder: edit the Brand / Mark constants and re-run this
  script, or
* use real artwork: overwrite the three PNGs in assets/icon/ (same names and
  specs as listed below) and run this script with --launcher-only. Update
  store/graphics/ by hand (or edit make_feature_graphic below).

One command regenerates everything (run from anywhere; paths are resolved
relative to this file):

    python3 assets/icon/generate_icon.py                  # art + launcher icons
    python3 assets/icon/generate_icon.py --art-only       # art only
    python3 assets/icon/generate_icon.py --launcher-only  # launcher icons only
    python3 assets/icon/generate_icon.py --art-only --preview /tmp/icon-preview

Requires Python 3.9+ and Pillow (in any venv:
`pip install -r assets/icon/requirements.txt`). The launcher step also needs
the Flutter SDK on PATH. The feature graphic uses the Roboto font (Apache-2.0)
that ships in the Flutter SDK cache
($FLUTTER_ROOT/bin/cache/artifacts/material_fonts); set ICON_FONT_DIR to a
folder containing Roboto-{Black,Bold,Medium}.ttf to use another copy.

Outputs (relative to the repo root)
-----------------------------------
assets/icon/icon.png             1024x1024 RGB, opaque (no alpha channel).
                                 Source for the iOS icons and the legacy
                                 (pre-API 26) Android icons.
assets/icon/icon_foreground.png  1024x1024 RGBA. Android adaptive-icon
                                 foreground. The PNG is the WHOLE 108 dp layer
                                 (hence adaptive_icon_foreground_inset: 0 in
                                 flutter_launcher_icons.yaml) and the mark
                                 stays inside the central 66 dp safe zone.
assets/icon/icon_monochrome.png  1024x1024 RGBA, white + alpha only. Android
                                 13+ themed-icon layer, same geometry.
assets/icon/icon.svg             Vector copy of icon.png.
store/graphics/icon-512.png      512x512 32-bit PNG (Play hi-res icon).
store/graphics/feature-graphic-1024x500.png
                                 1024x500 24-bit PNG, no alpha (Play feature
                                 graphic).

The launcher step runs `flutter pub get` and `dart run flutter_launcher_icons`
(config: flutter_launcher_icons.yaml) and then undoes a known
flutter_launcher_icons 0.14.4 bug that rewrites
ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS (a YES/NO build
setting) to "AppIcon" in ios/Runner.xcodeproj/project.pbxproj
(https://github.com/fluttercommunity/flutter_launcher_icons/issues/634).
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageColor, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - guidance for a missing dependency
    sys.exit("Pillow is required: python3 -m pip install pillow")

REPO_ROOT = Path(__file__).resolve().parents[2]
ICON_DIR = REPO_ROOT / "assets" / "icon"
STORE_DIR = REPO_ROOT / "store" / "graphics"

# ---------------------------------------------------------------------------
# Brand (PLACEHOLDER: swap in GOTTA.BIKE's real palette and wording)
# ---------------------------------------------------------------------------
# Near-black with a cool cast, in keeping with the app's dark Material 3 theme.
BACKGROUND = "#0E1116"
# Hi-vis yellow-green, like cycling safety kit: ~16:1 contrast on BACKGROUND,
# and it stays clear of the orange used by Strava and Zwift icons.
ACCENT = "#C6FF3D"
# Colour of the Android 13+ themed-icon layer. Only its alpha is used: the
# launcher tints it with the user's theme colour.
MONOCHROME = "#FFFFFF"

BRAND_LINE = "GOTTA.BIKE:"
PRODUCT_LINE = "BLE Watts"
TAGLINE = "Virtual BLE cycling power sensor"

# Everything is drawn this many times larger, then downscaled with LANCZOS.
SUPERSAMPLE = 4

# ---------------------------------------------------------------------------
# Mark geometry, in "mark units": the whole mark fits inside a circle of
# radius 1 around the origin (x to the right, y down).
# ---------------------------------------------------------------------------
# A point-symmetric zig-zag bolt: top tip, left elbow, lower notch,
# bottom tip, right elbow, upper notch. The tips overshoot because the
# rounding below trims them back.
BOLT_OUTLINE = (
    (0.25, -1.10),
    (-0.56, 0.18),
    (-0.18, 0.18),
    (-0.25, 1.10),
    (0.56, -0.18),
    (0.18, -0.18),
)
BOLT_SCALE = 0.88
BOLT_TIP_ROUNDING = 0.03  # fillet radius at the two tips
BOLT_CORNER_ROUNDING = 0.03  # fillet radius at the elbows and notches
BOLT_TIPS = (0, 3)  # indices into BOLT_OUTLINE

# Two broadcast arcs each side of the bolt, drawn as round-capped strokes.
ARC_WIDTH = 0.12
ARC_GAP = 0.12  # clear space between the two arcs
ARC_HALF_SWEEP_DEG = 43.0  # each arc spans +/- this angle around horizontal
ARC_RADII = (
    1.0 - ARC_WIDTH / 2 - ARC_WIDTH - ARC_GAP,  # inner arc (stroke centre)
    1.0 - ARC_WIDTH / 2,  # outer arc: its outer edge touches radius 1
)
MIN_BOLT_TO_ARC_CLEARANCE = 0.08

# Mark radius as a fraction of the canvas side.
FULL_BLEED_MARK_RADIUS = 0.34  # icon.png, icon-512.png (the OS masks corners)
# Adaptive layers are 108 dp. The logo must be at least 48 dp and stay inside
# the central 66 dp
# (https://developer.android.com/develop/ui/views/launch/icon_design_adaptive).
# 0.26 -> the mark is a 56 dp circle with a ~50 dp tall bolt.
ADAPTIVE_MARK_RADIUS = 0.26
ADAPTIVE_LAYER_DP = 108
ADAPTIVE_SAFE_ZONE_DP = 66
ADAPTIVE_VIEWPORT_DP = 72
ADAPTIVE_MIN_LOGO_DP = 48

Point = tuple[float, float]
Disc = tuple[float, float, float]  # centre x, centre y, radius


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
def _unit(x: float, y: float) -> Point:
    length = math.hypot(x, y)
    return x / length, y / length


def _filleted(points: list[Point], radii: list[float], steps: int = 12) -> list[Point]:
    """Replace each corner with a circular arc tangent to both edges.

    Works for convex and reflex corners alike (a reflex fillet fills the
    notch slightly). Each fillet must fit on its edges.
    """
    out: list[Point] = []
    count = len(points)
    for i, (px, py) in enumerate(points):
        radius = radii[i]
        ax, ay = points[i - 1]
        bx, by = points[(i + 1) % count]
        u1 = _unit(ax - px, ay - py)
        u2 = _unit(bx - px, by - py)
        cos_theta = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
        theta = math.acos(cos_theta)
        if radius <= 0 or theta < 1e-6 or math.pi - theta < 1e-6:
            out.append((px, py))
            continue
        tangent = radius / math.tan(theta / 2)
        bis = _unit(u1[0] + u2[0], u1[1] + u2[1])
        centre_dist = radius / math.sin(theta / 2)
        cx, cy = px + bis[0] * centre_dist, py + bis[1] * centre_dist
        t1 = (px + u1[0] * tangent, py + u1[1] * tangent)
        t2 = (px + u2[0] * tangent, py + u2[1] * tangent)
        a1 = math.atan2(t1[1] - cy, t1[0] - cx)
        a2 = math.atan2(t2[1] - cy, t2[0] - cx)
        sweep = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
        for k in range(steps + 1):
            angle = a1 + sweep * k / steps
            out.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return out


def bolt_polygon() -> list[Point]:
    scaled = [(x * BOLT_SCALE, y * BOLT_SCALE) for x, y in BOLT_OUTLINE]
    radii = [
        BOLT_TIP_ROUNDING if i in BOLT_TIPS else BOLT_CORNER_ROUNDING for i in range(len(scaled))
    ]
    return _filleted(scaled, radii)


def arc_strokes() -> list[tuple[float, float, float]]:
    """(stroke-centre radius, start angle, end angle) in degrees, y down."""
    strokes = []
    for radius in ARC_RADII:
        for centre in (0.0, 180.0):
            strokes.append((radius, centre - ARC_HALF_SWEEP_DEG, centre + ARC_HALF_SWEEP_DEG))
    return strokes


def _arc_band(radius: float, start: float, end: float, steps: int = 64) -> list[Point]:
    outer_r, inner_r = radius + ARC_WIDTH / 2, radius - ARC_WIDTH / 2
    angles = [math.radians(start + (end - start) * k / steps) for k in range(steps + 1)]
    outer = [(outer_r * math.cos(a), outer_r * math.sin(a)) for a in angles]
    inner = [(inner_r * math.cos(a), inner_r * math.sin(a)) for a in reversed(angles)]
    return outer + inner


def mark_shapes() -> tuple[list[list[Point]], list[Disc]]:
    """The mark as filled polygons plus round-cap discs, in mark units."""
    polygons = [bolt_polygon()]
    discs: list[Disc] = []
    for radius, start, end in arc_strokes():
        polygons.append(_arc_band(radius, start, end))
        for angle in (start, end):
            a = math.radians(angle)
            discs.append((radius * math.cos(a), radius * math.sin(a), ARC_WIDTH / 2))
    return polygons, discs


def check_geometry() -> str:
    """Fail fast if a parameter tweak breaks the layout rules.

    Returns a one-line summary of the adaptive-icon measurements.
    """
    polygons, discs = mark_shapes()
    extent = max(
        [math.hypot(x, y) for poly in polygons for x, y in poly]
        + [math.hypot(x, y) + r for x, y, r in discs]
    )
    if extent > 1.0 + 1e-9:
        raise SystemExit(f"mark extends to radius {extent:.3f}; it must fit in 1.0")
    # The bolt must keep clear of the inner arcs within their angular span
    # (plus the round caps).
    inner_edge = ARC_RADII[0] - ARC_WIDTH / 2
    cap_deg = math.degrees(math.asin((ARC_WIDTH / 2) / ARC_RADII[0]))
    limit = ARC_HALF_SWEEP_DEG + cap_deg
    worst = 0.0
    for x, y in polygons[0]:
        angle = math.degrees(math.atan2(y, x))
        off_axis = min(abs(angle), 180.0 - abs(angle))
        if off_axis <= limit:
            worst = max(worst, math.hypot(x, y))
    if inner_edge - worst < MIN_BOLT_TO_ARC_CLEARANCE:
        raise SystemExit(
            f"bolt reaches radius {worst:.3f} next to the inner arcs "
            f"(inner edge {inner_edge:.3f}); widen ARC_* or shrink the bolt"
        )
    # Adaptive layer: whole mark inside the safe zone, logo >= 48 dp.
    dp_per_unit = ADAPTIVE_MARK_RADIUS * ADAPTIVE_LAYER_DP
    if 2 * extent * dp_per_unit > ADAPTIVE_SAFE_ZONE_DP:
        raise SystemExit("ADAPTIVE_MARK_RADIUS puts the mark outside the 66 dp safe zone")
    bolt_ys = [y for _, y in polygons[0]]
    logo_h = (max(bolt_ys) - min(bolt_ys)) * dp_per_unit
    logo_w = 2 * extent * dp_per_unit
    if min(logo_w, logo_h) < ADAPTIVE_MIN_LOGO_DP:
        raise SystemExit(f"adaptive logo is {logo_w:.1f}x{logo_h:.1f} dp; it must be >= 48 dp")
    return (
        f"adaptive logo {logo_w:.1f} x {logo_h:.1f} dp (safe zone "
        f"{ADAPTIVE_SAFE_ZONE_DP} dp, minimum {ADAPTIVE_MIN_LOGO_DP} dp); "
        f"bolt-to-arc clearance {inner_edge - worst:.3f} mark units"
    )


# ---------------------------------------------------------------------------
# Raster helpers
# ---------------------------------------------------------------------------
def _rgb(color: str) -> tuple[int, int, int]:
    return ImageColor.getrgb(color)[:3]


def _mix(a: str, b: str, t: float) -> tuple[int, ...]:
    """Colour t of the way from a to b (flat stand-in for transparency)."""
    return tuple(round(x + (y - x) * t) for x, y in zip(_rgb(a), _rgb(b)))


def draw_mark(draw: ImageDraw.ImageDraw, cx: float, cy: float, radius: float, fill) -> None:
    """Draw the mark centred on (cx, cy) with the given radius in pixels."""
    polygons, discs = mark_shapes()
    for poly in polygons:
        draw.polygon([(cx + x * radius, cy + y * radius) for x, y in poly], fill=fill)
    for x, y, r in discs:
        draw.ellipse(
            [
                cx + (x - r) * radius,
                cy + (y - r) * radius,
                cx + (x + r) * radius,
                cy + (y + r) * radius,
            ],
            fill=fill,
        )


def mark_mask(size: int, radius_fraction: float) -> Image.Image:
    """Anti-aliased 8-bit mask of the mark centred on a size x size canvas."""
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    draw_mark(ImageDraw.Draw(mask), big / 2, big / 2, radius_fraction * big, 255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def make_full_bleed(size: int) -> Image.Image:
    """Opaque RGB square: BACKGROUND with the ACCENT mark."""
    image = Image.new("RGB", (size, size), _rgb(BACKGROUND))
    image.paste(_rgb(ACCENT), (0, 0, size, size), mark_mask(size, FULL_BLEED_MARK_RADIUS))
    return image


def make_layer(size: int, color: str) -> Image.Image:
    """Transparent RGBA adaptive-icon layer holding only the mark."""
    layer = Image.new("RGBA", (size, size), _rgb(color) + (0,))
    layer.putalpha(mark_mask(size, ADAPTIVE_MARK_RADIUS))
    return layer


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------
def _num(value: float) -> str:
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text == "-0" else text


def make_svg(size: int = 1024) -> str:
    c, s = size / 2, FULL_BLEED_MARK_RADIUS * size
    bolt = bolt_polygon()
    bolt_d = "M" + " L".join(f"{_num(c + x * s)} {_num(c + y * s)}" for x, y in bolt) + " Z"
    arcs = []
    for radius, start, end in arc_strokes():
        r = radius * s
        x0 = c + r * math.cos(math.radians(start))
        y0 = c + r * math.sin(math.radians(start))
        x1 = c + r * math.cos(math.radians(end))
        y1 = c + r * math.sin(math.radians(end))
        arcs.append(
            f'    <path d="M{_num(x0)} {_num(y0)} A{_num(r)} {_num(r)} 0 0 1 '
            f'{_num(x1)} {_num(y1)}"/>'
        )
    return "\n".join(
        [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">',
            "  <title>GOTTA.BIKE: BLE Watts (placeholder mark)</title>",
            "  <!-- Generated by assets/icon/generate_icon.py; edit that, not this. -->",
            f'  <rect width="{size}" height="{size}" fill="{BACKGROUND}"/>',
            f'  <path fill="{ACCENT}" d="{bolt_d}"/>',
            f'  <g fill="none" stroke="{ACCENT}" stroke-width="{_num(ARC_WIDTH * s)}" '
            'stroke-linecap="round">',
            *arcs,
            "  </g>",
            "</svg>",
            "",
        ]
    )


# ---------------------------------------------------------------------------
# Play Store feature graphic
# ---------------------------------------------------------------------------
FONT_FILES = {
    "black": "Roboto-Black.ttf",
    "bold": "Roboto-Bold.ttf",
    "medium": "Roboto-Medium.ttf",
}


def _font_dirs() -> list[Path]:
    dirs = []
    if os.environ.get("ICON_FONT_DIR"):
        dirs.append(Path(os.environ["ICON_FONT_DIR"]))
    roots = []
    if os.environ.get("FLUTTER_ROOT"):
        roots.append(Path(os.environ["FLUTTER_ROOT"]))
    flutter = shutil.which("flutter")
    if flutter:
        roots.append(Path(flutter).resolve().parent.parent)
    dirs += [root / "bin" / "cache" / "artifacts" / "material_fonts" for root in roots]
    return dirs


def _font(weight: str, px: float) -> ImageFont.FreeTypeFont:
    for folder in _font_dirs():
        path = folder / FONT_FILES[weight]
        if path.is_file():
            return ImageFont.truetype(str(path), round(px))
    raise SystemExit(
        f"{FONT_FILES[weight]} not found. Install Flutter (its SDK cache ships "
        "Roboto) or set ICON_FONT_DIR to a folder with the Roboto TTFs."
    )


def _ink_left(font: ImageFont.FreeTypeFont, text: str) -> float:
    """Distance from the pen position to the first inked pixel."""
    return font.getbbox(text, anchor="ls")[0]


def _cap_height(font: ImageFont.FreeTypeFont) -> float:
    return -font.getbbox("H", anchor="ls")[1]


def _tracked_width(font: ImageFont.FreeTypeFont, text: str, tracking: float) -> float:
    return sum(font.getlength(ch) for ch in text) + tracking * (len(text) - 1)


def _draw_tracked(draw, x: float, y: float, text: str, font, fill, tracking: float) -> None:
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill, anchor="ls")
        x += font.getlength(ch) + tracking


def make_feature_graphic(width: int = 1024, height: int = 500) -> Image.Image:
    """Mark + app name + tagline on an ACCENT field, 24-bit RGB.

    Play asks for a vibrant background (not white, black or dark grey), the
    focal point near the centre and nothing important near the edges, so the
    brand colours are inverted here and the lock-up is centred.
    """
    ss = SUPERSAMPLE
    w, h = width * ss, height * ss
    image = Image.new("RGB", (w, h), _rgb(ACCENT))
    draw = ImageDraw.Draw(image)

    ink = _rgb(BACKGROUND)
    soft_ink = _mix(BACKGROUND, ACCENT, 0.25)
    motif = _mix(ACCENT, BACKGROUND, 0.07)

    # Background motif hugging the left/right edges: faint broadcast arcs that
    # echo the mark. They stop ~120 px in, well clear of the lock-up.
    stroke = round(16 * ss)
    for side in (-1, 1):
        ox = w / 2 + side * (w / 2 + 250 * ss)
        start, end = (-40, 40) if side < 0 else (140, 220)
        for i in range(3):
            r = (280 + 40 * i) * ss
            draw.arc([ox - r, h / 2 - r, ox + r, h / 2 + r], start, end, fill=motif, width=stroke)

    brand_font = _font("bold", 34 * ss)
    product_font = _font("black", 100 * ss)
    tagline_font = _font("medium", 31 * ss)
    tracking = 5.0 * ss
    brand_to_product = 16 * ss  # gap between one baseline and the next cap top
    product_to_tagline = 24 * ss

    text_w = max(
        _tracked_width(brand_font, BRAND_LINE, tracking),
        product_font.getlength(PRODUCT_LINE) - _ink_left(product_font, PRODUCT_LINE),
        tagline_font.getlength(TAGLINE) - _ink_left(tagline_font, TAGLINE),
    )
    block_h = (
        _cap_height(brand_font)
        + brand_to_product
        + _cap_height(product_font)
        + product_to_tagline
        + _cap_height(tagline_font)
    )

    mark_radius = 106 * ss
    gap = 46 * ss
    group_w = 2 * mark_radius + gap + text_w
    left = (w - group_w) / 2

    draw_mark(draw, left + mark_radius, h / 2, mark_radius, ink)

    # Text column, vertically centred from the first cap top to the last
    # baseline, each line's ink aligned to the same left edge.
    x = left + 2 * mark_radius + gap
    y = (h - block_h) / 2 + _cap_height(brand_font)
    _draw_tracked(
        draw, x - _ink_left(brand_font, BRAND_LINE), y, BRAND_LINE, brand_font, soft_ink, tracking
    )
    y += brand_to_product + _cap_height(product_font)
    draw.text(
        (x - _ink_left(product_font, PRODUCT_LINE), y),
        PRODUCT_LINE,
        font=product_font,
        fill=ink,
        anchor="ls",
    )
    y += product_to_tagline + _cap_height(tagline_font)
    draw.text(
        (x - _ink_left(tagline_font, TAGLINE), y),
        TAGLINE,
        font=tagline_font,
        fill=soft_ink,
        anchor="ls",
    )

    return image.resize((width, height), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------------------
# Previews (for eyeballing masks and small sizes; never committed)
# ---------------------------------------------------------------------------
def _superellipse(size: int, n: float = 5.0, steps: int = 720) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    half = size / 2
    points = []
    for k in range(steps):
        t = 2 * math.pi * k / steps
        c, s = math.cos(t), math.sin(t)
        points.append(
            (
                half + half * math.copysign(abs(c) ** (2 / n), c),
                half + half * math.copysign(abs(s) ** (2 / n), s),
            )
        )
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def _masked(image: Image.Image, shape: str) -> Image.Image:
    big = image.size[0] * SUPERSAMPLE
    if shape == "circle":
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, big - 1, big - 1], fill=255)
    elif shape == "rounded":
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, big - 1, big - 1], radius=big * 0.22, fill=255
        )
    else:
        mask = _superellipse(big)
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image, (0, 0), mask.resize(image.size, Image.Resampling.LANCZOS))
    return out


def _adaptive(foreground: Image.Image, background: str, px: int) -> Image.Image:
    """What a launcher shows: the central 72 dp of the 108 dp layers."""
    layer = Image.new("RGBA", foreground.size, _rgb(background) + (255,))
    layer.alpha_composite(foreground)
    side = foreground.size[0]
    crop = side * (ADAPTIVE_LAYER_DP - ADAPTIVE_VIEWPORT_DP) / ADAPTIVE_LAYER_DP / 2
    viewport = layer.crop((round(crop), round(crop), round(side - crop), round(side - crop)))
    return viewport.resize((px, px), Image.Resampling.LANCZOS)


def write_previews(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    icon = Image.open(ICON_DIR / "icon.png").convert("RGBA")
    fg = Image.open(ICON_DIR / "icon_foreground.png").convert("RGBA")
    mono = Image.open(ICON_DIR / "icon_monochrome.png").convert("RGBA")

    icon.resize((48, 48), Image.Resampling.LANCZOS).save(folder / "icon-48.png")
    _masked(_adaptive(fg, BACKGROUND, 48), "circle").save(folder / "adaptive-circle-48.png")

    # Safe-zone overlay on the 108 dp foreground layer.
    overlay = Image.new("RGBA", fg.size, _rgb("#30343B") + (255,))
    overlay.alpha_composite(fg)
    d = ImageDraw.Draw(overlay)
    side = fg.size[0]
    for dp, color in ((ADAPTIVE_VIEWPORT_DP, "#4FC3F7"), (ADAPTIVE_SAFE_ZONE_DP, "#FF5252")):
        inset = side * (ADAPTIVE_LAYER_DP - dp) / ADAPTIVE_LAYER_DP / 2
        box = [inset, inset, side - inset, side - inset]
        d.ellipse(box, outline=color, width=4)
        if dp == ADAPTIVE_VIEWPORT_DP:
            d.rectangle(box, outline=color, width=4)
    overlay.save(folder / "safe-zone.png")

    # Contact sheet: iOS-like, Android masks, themed icon, small sizes.
    themed_fg = Image.new("RGBA", mono.size, _rgb("#2E3B0E") + (0,))
    themed_fg.putalpha(mono.getchannel("A"))
    tiles = [
        _masked(icon.resize((192, 192), Image.Resampling.LANCZOS), "rounded"),
        _masked(_adaptive(fg, BACKGROUND, 192), "circle"),
        _masked(_adaptive(fg, BACKGROUND, 192), "squircle"),
        _masked(_adaptive(fg, BACKGROUND, 192), "rounded"),
        _masked(_adaptive(themed_fg, "#DDE8C0", 192), "circle"),
    ]
    small = [
        _masked(icon.resize((48, 48), Image.Resampling.LANCZOS), "rounded"),
        _masked(_adaptive(fg, BACKGROUND, 48), "circle"),
        _masked(_adaptive(fg, BACKGROUND, 48), "squircle"),
        _masked(_adaptive(fg, BACKGROUND, 48), "rounded"),
        _masked(_adaptive(themed_fg, "#DDE8C0", 48), "circle"),
    ]
    for background, name in (("#F1F3F4", "sheet-light.png"), ("#202124", "sheet-dark.png")):
        sheet = Image.new("RGBA", (5 * 216 + 24, 216 + 72 + 24), _rgb(background) + (255,))
        for i, (tile, tiny) in enumerate(zip(tiles, small)):
            sheet.alpha_composite(tile, (24 + i * 216, 24))
            sheet.alpha_composite(tiny, (24 + i * 216 + 72, 216 + 24))
        sheet.convert("RGB").save(folder / name)
    print(f"previews written to {folder}")


# ---------------------------------------------------------------------------
# flutter_launcher_icons
# ---------------------------------------------------------------------------
SYMBOL_EXTENSIONS_SETTING = "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"


def _repair_pbxproj(path: Path, before: bytes) -> None:
    after = path.read_bytes()
    if after == before:
        return
    old_lines = before.decode("utf-8").splitlines()
    new_lines = after.decode("utf-8").splitlines()
    if len(old_lines) != len(new_lines):
        print(f"warning: {path} changed shape; review it with `git diff`")
        return
    restored = 0
    for i, (old, new) in enumerate(zip(old_lines, new_lines)):
        if old != new and SYMBOL_EXTENSIONS_SETTING in old:
            new_lines[i] = old
            restored += 1
    text = "\n".join(new_lines) + "\n"
    path.write_bytes(before if text.encode("utf-8") == before else text.encode("utf-8"))
    if restored:
        print(
            f"restored {restored} {SYMBOL_EXTENSIONS_SETTING} line(s) in "
            f"{path.relative_to(REPO_ROOT)} (flutter_launcher_icons issue #634)"
        )
    if path.read_bytes() != before:
        print(f"note: flutter_launcher_icons changed other lines in {path}; review them")


def run_launcher_icons() -> None:
    flutter, dart = shutil.which("flutter"), shutil.which("dart")
    if not flutter or not dart:
        raise SystemExit("flutter and dart must be on PATH for the launcher step")
    pbxproj = REPO_ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    manifest = REPO_ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    pbxproj_before = pbxproj.read_bytes() if pbxproj.exists() else None
    manifest_before = manifest.read_bytes() if manifest.exists() else None

    subprocess.run([flutter, "pub", "get"], cwd=REPO_ROOT, check=True)
    subprocess.run([dart, "run", "flutter_launcher_icons"], cwd=REPO_ROOT, check=True)

    if pbxproj_before is not None:
        _repair_pbxproj(pbxproj, pbxproj_before)
    if manifest_before is not None and manifest.read_bytes() != manifest_before:
        print(f"note: flutter_launcher_icons changed {manifest}; review it")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print(f"wrote {path.relative_to(REPO_ROOT)}  {image.size[0]}x{image.size[1]} {image.mode}")


def write_art() -> None:
    print(check_geometry())
    _save(make_full_bleed(1024), ICON_DIR / "icon.png")
    _save(make_layer(1024, ACCENT), ICON_DIR / "icon_foreground.png")
    _save(make_layer(1024, MONOCHROME), ICON_DIR / "icon_monochrome.png")
    (ICON_DIR / "icon.svg").write_text(make_svg(), encoding="utf-8")
    print("wrote assets/icon/icon.svg")
    _save(make_full_bleed(512).convert("RGBA"), STORE_DIR / "icon-512.png")
    _save(make_feature_graphic(), STORE_DIR / "feature-graphic-1024x500.png")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--art-only",
        action="store_true",
        help="draw the PNG/SVG art but skip flutter_launcher_icons",
    )
    group.add_argument(
        "--launcher-only",
        action="store_true",
        help="only run flutter_launcher_icons on the existing PNGs",
    )
    parser.add_argument(
        "--preview", type=Path, metavar="DIR", help="also write mask / small-size previews to DIR"
    )
    args = parser.parse_args(argv)
    # Keep our messages in order with the Flutter subprocess output.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    if not args.launcher_only:
        write_art()
    if not args.art_only:
        run_launcher_icons()
    if args.preview:
        write_previews(args.preview)


if __name__ == "__main__":
    main()
