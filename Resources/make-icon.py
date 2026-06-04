# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Generates the Clawdi app icon (ClawdiIcon.png + Clawdi.icns) from the
flower-claude skin pose data.

Pipeline: take the `cat-idle-follow-v2` pose from flower-poses.json, strip the
blink overlay (the static SVG stacks the closed-eye layer the app toggles at
runtime), inject the tail from components.tailPathD at its data-patch-frame
origin (mirroring PixelCompositor.drawGeneratedComponentIfNeeded), nudge the
pupils and mouth for a bottom-right glance, then render, add the white sticker
outline, and compose onto a cream squircle on Apple's 824/1024 icon grid.

Requires: rsvg-convert (brew install librsvg), iconutil (macOS).
Run: uv run Resources/make-icon.py
"""

import copy
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).parent
POSES = ROOT / "skins" / "flower-claude" / "flower-poses.json"
OUT_PNG = ROOT / "ClawdiIcon.png"
OUT_ICNS = ROOT / "Clawdi.icns"

POSE_NAME = "cat-idle-follow-v2"
VIEWBOX_UNITS = 50          # pose viewBox is "-8 -10 50 50"
VIEWBOX_ORIGIN_X = -8
HEAD_CENTER_X = 14          # in viewBox units; icon is centered on the head, not the bbox (tail skews it)
RENDER_PX = 2000            # working raster of the pose
CANVAS = 2048               # working icon canvas, downscaled to the 1024 master
MASTER = 1024
STICKER_PAD = 60            # transparent margin so the outline dilation has room
STICKER_RADIUS = 40
FILL_FRAC = 0.80            # character height/width as a fraction of the canvas
CREAM = (240, 238, 230, 255)  # anthropic pampas
# Apple Big Sur icon grid, in 1024ths
GRID_MARGIN = 100 / 1024
GRID_RADIUS = 185.4 / 1024
# bottom-right glance: pupil rects move from (8|17, 11) and the mouth follows
PUPIL_POS = {"pupil-left": ("9", "12"), "pupil-right": ("18", "12")}
MOUTH_SHIFT = "translate(1,0.5)"


def to_svg(node: dict) -> str:
    attrs = " ".join(f'{k}="{v}"' for k, v in node.get("attrs", {}).items())
    inner = node.get("text", "") + "".join(to_svg(c) for c in node.get("children", []))
    if not inner:
        return f"<{node['tag']} {attrs}/>"
    return f"<{node['tag']} {attrs}>{inner}</{node['tag']}>"


def find(node: dict, ident: str) -> dict | None:
    if node.get("attrs", {}).get("id") == ident:
        return node
    for c in node.get("children", []):
        if (r := find(c, ident)) is not None:
            return r
    return None


def prune(node: dict, pred) -> None:
    node["children"] = [c for c in node.get("children", []) if not pred(c)]
    for c in node["children"]:
        prune(c, pred)


def build_pose_svg(data: dict) -> str:
    pose = copy.deepcopy(next(p for p in data["poses"] if p["name"] == POSE_NAME))
    root = pose["root"]

    # open the eyes: drop the blink overlay rects (class="closed-eye-line")
    prune(root, lambda n: "closed-eye-line" in (
        str(n.get("attrs", {}).get("id", "")) + str(n.get("attrs", {}).get("class", ""))
    ))

    # inject the tail the way PixelCompositor does: translate to the
    # data-patch-frame origin and draw components.tailPathD with the group fill
    tail = find(root, "tail")
    fx, fy, *_ = tail["attrs"]["data-patch-frame"].split()
    tail["attrs"]["transform"] = f"translate({fx},{fy})"
    tail["children"] = [{"tag": "path", "attrs": {"d": data["components"]["tailPathD"]}, "children": []}]

    # glance bottom-right
    for pid, (x, y) in PUPIL_POS.items():
        pupil = find(root, pid)
        pupil["attrs"]["x"], pupil["attrs"]["y"] = x, y
    face = find(root, "face-js")

    def is_mouth(n: dict) -> bool:
        a = n.get("attrs", {})
        return n["tag"] == "path" and a.get("fill") == "none" and a.get("stroke") == "#241f1d"

    stack = [face]
    while stack:
        n = stack.pop()
        if is_mouth(n):
            n["attrs"]["transform"] = MOUTH_SHIFT
            break
        stack.extend(n.get("children", []))

    return to_svg(root)


def sticker(img: Image.Image, radius: int) -> Image.Image:
    """White outline: dilate the alpha (two MaxFilter passes ~ a disk), fill
    white, composite the art on top."""
    dilated = img.getchannel("A")
    k = radius // 2 * 2 + 1
    for _ in range(2):
        dilated = dilated.filter(ImageFilter.MaxFilter(k))
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(Image.new("RGBA", img.size, (255, 255, 255, 255)), mask=dilated)
    out.alpha_composite(img)
    return out


def compose(svg: str, tmp: Path) -> Image.Image:
    svg_path = tmp / "pose.svg"
    raster = tmp / "pose.png"
    svg_path.write_text(svg)
    subprocess.run(
        ["rsvg-convert", "-w", str(RENDER_PX), "-h", str(RENDER_PX), str(svg_path), "-o", str(raster)],
        check=True,
    )
    full = Image.open(raster).convert("RGBA")
    bb = full.getbbox()
    sprite = full.crop(bb)
    ppu = RENDER_PX / VIEWBOX_UNITS
    head_x = (HEAD_CENTER_X - VIEWBOX_ORIGIN_X) * ppu - bb[0]

    padded = Image.new("RGBA", (sprite.width + 2 * STICKER_PAD, sprite.height + 2 * STICKER_PAD), (0, 0, 0, 0))
    padded.paste(sprite, (STICKER_PAD, STICKER_PAD))
    outlined = sticker(padded, STICKER_RADIUS)
    sbb = outlined.getbbox()
    outlined = outlined.crop(sbb)
    head_x += STICKER_PAD - sbb[0]

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    margin = round(CANVAS * GRID_MARGIN)
    draw.rounded_rectangle(
        [margin, margin, CANVAS - margin, CANVAS - margin],
        radius=round(CANVAS * GRID_RADIUS),
        fill=CREAM,
    )
    box = round(CANVAS * FILL_FRAC)
    scale = min(box / outlined.width, box / outlined.height)
    art = outlined.resize((round(outlined.width * scale), round(outlined.height * scale)), Image.LANCZOS)
    canvas.alpha_composite(art, (round(CANVAS / 2 - head_x * scale), (CANVAS - art.height) // 2))
    return canvas.resize((MASTER, MASTER), Image.LANCZOS)


def export(master: Image.Image, tmp: Path) -> None:
    master.resize((512, 512), Image.LANCZOS).save(OUT_PNG)
    iconset = tmp / "Clawdi.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        master.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        double = size * 2
        scaled = master if double == MASTER else master.resize((double, double), Image.LANCZOS)
        scaled.save(iconset / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)], check=True)


def main() -> None:
    if shutil.which("rsvg-convert") is None:
        raise SystemExit("rsvg-convert not found: brew install librsvg")
    data = json.loads(POSES.read_text())
    with tempfile.TemporaryDirectory() as tmp:
        master = compose(build_pose_svg(data), Path(tmp))
        export(master, Path(tmp))
    print(f"wrote {OUT_PNG} and {OUT_ICNS}")


if __name__ == "__main__":
    main()
