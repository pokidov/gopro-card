#!/usr/bin/env python3
"""Generates the icon and marketing screenshots for GoPro Card.

Visual language: black field, white glyph, condensed uppercase type (DIN, the family
GoPro's own lockups sit in), and a single electric-blue accent.

    python3 Tools/make_assets.py

Outputs:
    Resources/AppIcon.icns          icon used by the .app bundle
    appstore/icon/icon_1024.png     master artwork
    appstore/screenshots/*.png      1280x800 screenshots
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "appstore" / "icon"
SHOT_DIR = ROOT / "appstore" / "screenshots"
RESOURCES = ROOT / "Resources"

BLUE = (0, 163, 224)
WHITE = (255, 255, 255)
GREY = (152, 156, 162)
PANEL = (20, 20, 20)
PANEL_HI = (28, 28, 28)

DIN = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
DIN_ALT = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
SF = "/System/Library/Fonts/SFNS.ttf"


def display(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(DIN, size)


def display_wide(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(DIN_ALT, size)


def text(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    try:
        f = ImageFont.truetype(SF, size)
        f.set_variation_by_name(weight)
        return f
    except Exception:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)


# ---------------------------------------------------------------- primitives


def vertical_gradient(size, top, bottom):
    w, h = size
    base = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        base.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return base.resize((w, h), Image.BILINEAR)


def tracked(draw, xy, string, font, fill, spacing=0):
    """Draw with letter-spacing — GoPro-style caps need air between letters."""
    x, y = xy
    for ch in string:
        draw.text((x, y), ch, font=font, fill=fill, anchor="ls")
        x += draw.textlength(ch, font=font) + spacing
    return x


# --------------------------------------------------------------------- icon

SS = 4


def draw_icon(target=1024):
    size = target * SS
    k = size / 1024.0

    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inset = int(size * 0.098)
    body = size - inset * 2
    radius = int(body * 0.224)

    bg = vertical_gradient((body, body), (22, 22, 24), (0, 0, 0))

    spad = int(body * 0.10)
    shadow = Image.new("L", (body + 2 * spad, body + 2 * spad), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (spad, spad, spad + body, spad + body), radius=radius, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18 * k))
    drop = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    drop.paste(Image.new("RGBA", shadow.size, (0, 0, 0, 255)),
               (inset - spad, inset - spad + int(10 * k)), shadow)
    icon.alpha_composite(drop)

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body, body), radius=radius, fill=255)
    layer = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    layer.paste(bg.convert("RGBA"), (0, 0), mask)

    # hairline edge so a black square still reads on a dark wallpaper
    edge = ImageDraw.Draw(layer)
    edge.rounded_rectangle((0, 0, body - 1, body - 1), radius=radius,
                           outline=(255, 255, 255, 26), width=max(1, int(2 * k)))
    icon.alpha_composite(layer, (inset, inset))

    # ---- white SD card
    card_w, card_h = int(body * 0.46), int(body * 0.565)
    chamfer = int(card_w * 0.30)
    card_radius = int(card_w * 0.13)

    card_mask = Image.new("L", (card_w, card_h), 0)
    cm = ImageDraw.Draw(card_mask)
    cm.rounded_rectangle((0, 0, card_w, card_h), radius=card_radius, fill=255)
    cm.polygon([(card_w - chamfer, -2), (card_w + 2, -2), (card_w + 2, chamfer)], fill=0)

    card = vertical_gradient((card_w, card_h), (255, 255, 255), (226, 231, 236)).convert("RGBA")
    card.putalpha(card_mask)

    cdraw = ImageDraw.Draw(card)
    pin_w, pin_h = int(card_w * 0.080), int(card_h * 0.045)
    gap = int(card_w * 0.042)
    total = pin_w * 6 + gap * 5
    px = (card_w - total) // 2
    py = int(card_h * 0.115)
    for _ in range(6):
        cdraw.rounded_rectangle((px, py, px + pin_w, py + pin_h),
                                radius=max(2, pin_h // 4), fill=(28, 28, 30))
        px += pin_w + gap

    # lens: black well, electric-blue ring
    cx, cy = card_w // 2, int(card_h * 0.635)
    r_out = int(card_w * 0.30)
    cdraw.ellipse((cx - r_out, cy - r_out, cx + r_out, cy + r_out), fill=(0, 0, 0))
    r_ring = int(r_out * 0.80)
    cdraw.ellipse((cx - r_ring, cy - r_ring, cx + r_ring, cy + r_ring), fill=BLUE)
    r_in = int(r_out * 0.52)
    cdraw.ellipse((cx - r_in, cy - r_in, cx + r_in, cy + r_in), fill=(0, 0, 0))
    r_gl = int(r_out * 0.16)
    cdraw.ellipse((cx - r_in + int(8 * k), cy - r_in + int(8 * k),
                   cx - r_in + int(8 * k) + r_gl, cy - r_in + int(8 * k) + r_gl),
                  fill=WHITE)

    cpad = int(card_w * 0.30)
    card_shadow = Image.new("L", (card_w + 2 * cpad, card_h + 2 * cpad), 0)
    card_shadow.paste(card_mask, (cpad, cpad))
    card_shadow = card_shadow.filter(ImageFilter.GaussianBlur(14 * k))
    cs = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cs.paste(Image.new("RGBA", card_shadow.size, (0, 0, 0, 255)),
             ((size - card_shadow.width) // 2,
              (size - card_shadow.height) // 2 + int(10 * k)), card_shadow)
    icon.alpha_composite(cs)

    icon.alpha_composite(card, ((size - card_w) // 2, (size - card_h) // 2))
    return icon.resize((target, target), Image.LANCZOS)


# ---------------------------------------------------------------- screenshots

W, H = 1280, 800
WIN_W, WIN_H = 690, 466
WIN_X, WIN_Y = 566, 172


def backdrop():
    img = vertical_gradient((W, H), (18, 18, 20), (0, 0, 0)).convert("RGBA")
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse((520, 120, 1340, 820), fill=80)
    mask = mask.filter(ImageFilter.GaussianBlur(150))
    glow = Image.new("RGB", (W, H), (10, 54, 74))
    return Image.composite(glow, img.convert("RGB"), mask).convert("RGBA")


def mock_finder(width=WIN_W, height=WIN_H, title="100GOPRO"):
    win = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(win)

    d.rounded_rectangle((0, 0, width, height), radius=14, fill=PANEL + (255,),
                        outline=(255, 255, 255, 34), width=1)
    d.rounded_rectangle((0, 0, width, 46), radius=14, fill=PANEL_HI + (255,))
    d.rectangle((0, 32, width, 46), fill=PANEL_HI + (255,))

    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 22 + i * 21
        d.ellipse((cx - 6, 17, cx + 6, 29), fill=c)

    d.text((width / 2, 25), title, font=display_wide(19), fill=WHITE, anchor="mm")

    d.rectangle((0, 46, 176, height), fill=(10, 10, 10, 255))
    y = 72
    for name in ["Recents", "Shared", "Desktop", "Documents", "Downloads"]:
        d.rounded_rectangle((18, y, 31, y + 13), radius=2, fill=(70, 72, 76))
        d.text((44, y + 7), name, font=text(13), fill=(158, 160, 166), anchor="lm")
        y += 31

    d.text((18, 248), "LOCATIONS", font=display(13), fill=(120, 122, 128))
    d.rectangle((18, 268, 28, 278), fill=BLUE)
    d.text((40, 273), "HERO13 Black", font=text(13, "Semibold"), fill=WHITE, anchor="lm")

    name_x, date_x, size_x = 200, 462, 610
    header = display(14)
    for label, x in [("NAME", name_x), ("DATE MODIFIED", date_x), ("SIZE", size_x)]:
        d.text((x, 72), label, font=header, fill=(128, 130, 136), anchor="ls")
    d.rectangle((name_x - 14, 88, width - 14, 89), fill=(255, 255, 255, 26))

    files = [
        ("GX010078.MP4", "29.7.2025 at 18:26", "107,3 MB"),
        ("GX010077.MP4", "29.7.2025 at 18:24", "63,4 MB"),
        ("GX010076.MP4", "29.7.2025 at 18:21", "226,8 MB"),
        ("GOPR0075.JPG", "26.9.2025 at 20:21", "3,8 MB"),
        ("GOPR0074.JPG", "26.9.2025 at 20:20", "3,9 MB"),
        ("GX010073.MP4", "24.8.2025 at 16:04", "60,2 MB"),
        ("GX010072.MP4", "24.8.2025 at 16:00", "55,1 MB"),
        ("GX010071.MP4", "24.8.2025 at 15:59", "219,4 MB"),
    ]

    y = 104
    for i, (name, date, size) in enumerate(files):
        selected = (i == 1)
        if selected:
            d.rounded_rectangle((name_x - 14, y - 6, width - 12, y + 24), radius=5, fill=BLUE + (255,))
        chip = WHITE if name.endswith(".JPG") else BLUE
        if selected:
            chip = WHITE
        text_col = WHITE if selected else (226, 228, 232)
        meta_col = WHITE if selected else (146, 148, 154)
        d.rounded_rectangle((name_x, y, name_x + 14, y + 16), radius=2, fill=chip)
        d.text((name_x + 24, y + 9), name, font=text(13), fill=text_col, anchor="lm")
        d.text((date_x, y + 9), date, font=text(13), fill=meta_col, anchor="lm")
        d.text((size_x, y + 9), size, font=text(13), fill=meta_col, anchor="lm")
        y += 43

    clip = Image.new("L", (width, height), 0)
    ImageDraw.Draw(clip).rounded_rectangle((0, 0, width, height), radius=14, fill=255)
    r, g, b, a = win.split()
    return Image.merge("RGBA", (r, g, b, ImageChops.multiply(a, clip)))


def screenshot(eyebrow, headline, sub, bullets, shot_name):
    img = backdrop()
    d = ImageDraw.Draw(img)
    x = 72

    end = tracked(d, (x, 176), eyebrow[0], display(26), WHITE, spacing=7)
    tracked(d, (end + 10, 176), eyebrow[1], display(26), BLUE, spacing=7)

    head = display(86)
    y = 250
    for line in headline:
        d.text((x, y), line, font=head, fill=WHITE, anchor="ls")
        y += 72

    d.text((x, y + 16), sub, font=text(19), fill=GREY, anchor="ls")

    y += 76
    for b in bullets:
        d.rectangle((x, y - 4, x + 7, y + 3), fill=BLUE)
        d.text((x + 20, y + 5), b, font=display(22), fill=(210, 212, 216), anchor="ls")
        y += 36

    win = mock_finder()
    pad = 90
    shadow = Image.new("L", (WIN_W + pad * 2, WIN_H + pad * 2), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad, pad + WIN_W, pad + WIN_H),
                                             radius=14, fill=200)
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    layer.paste(Image.new("RGBA", shadow.size, (0, 0, 0, 255)),
                (WIN_X - pad, WIN_Y + 16 - pad), shadow)
    img.alpha_composite(layer)
    img.alpha_composite(win, (WIN_X, WIN_Y))

    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(SHOT_DIR / shot_name, "PNG", optimize=True)
    print("wrote", SHOT_DIR / shot_name)


# ---------------------------------------------------------------------- main


def build_icns(master):
    RESOURCES.mkdir(exist_ok=True)
    iconset = ROOT / "build" / "AppIcon.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    iconset.mkdir(parents=True, exist_ok=True)

    for name, px in [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]:
        master.resize((px, px), Image.LANCZOS).save(iconset / name, "PNG")

    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o",
                    str(RESOURCES / "AppIcon.icns")], check=True)
    print("wrote", RESOURCES / "AppIcon.icns")


def main():
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    icon = draw_icon(1024)
    icon.save(ICON_DIR / "icon_1024.png", "PNG", optimize=True)
    print("wrote", ICON_DIR / "icon_1024.png")
    build_icns(icon)

    screenshot(
        ("GOPRO", "CARD"),
        ["YOUR GOPRO IS", "A FINDER DRIVE"],
        "One cable. No reader, no import.",
        ["MOUNTS AUTOMATICALLY ON PLUG-IN", "BROWSE AND COPY IN FINDER", "BYTE-IDENTICAL COPIES"],
        "01-finder-drive.png",
    )
    screenshot(
        ("GOPRO", "CARD"),
        ["COPY FOOTAGE", "AT FULL SPEED"],
        "Drag files out like any other disk.",
        ["SEEK INSIDE CLIPS INSTANTLY", "VERIFIED BYTE-FOR-BYTE", "EJECT WHEN YOU ARE DONE"],
        "02-copy.png",
    )
    screenshot(
        ("GOPRO", "CARD"),
        ["IT LIVES IN", "THE MENU BAR"],
        "Mount, unmount, or open the card.",
        ["NO WINDOWS TO MANAGE", "STARTS AT LOGIN", "READ-ONLY, SO NOTHING IS LOST"],
        "03-menu-bar.png",
    )


if __name__ == "__main__":
    main()
