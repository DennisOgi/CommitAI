"""Build platform-correct brand assets from the supplied Commit logo artwork.

Inputs (assets/branding/source):  icon_original.png, logo_horizontal_original.png
Outputs (assets/branding):
  icon.png             1024 full-bleed blue gradient + centred phone glyph (iOS, Windows, legacy Android;
                       platforms apply their own corner mask)
  icon_foreground.png  1024 glyph only, inside the Android adaptive-icon safe zone
  splash.png           512  rounded-square mark (as supplied, cleaned, centred) for the launch screen
  logo_mark.png        512  same rounded-square mark for use inside the app
  logo_wordmark.png         horizontal logo cropped to its shape, transparent around it
  glyph.png            512  white glyph alone (transparent) for in-app use on any background
Prints the sampled gradient colours so the app theme can match them exactly.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

root = Path(sys.argv[1])
src = root / "source"
icon_src = Image.open(src / "icon_original.png").convert("RGBA")
word_src = Image.open(src / "logo_horizontal_original.png").convert("RGBA")


def shape_bbox(im):
    a = im.getchannel("A").point(lambda v: 255 if v > 200 else 0)
    return a.getbbox()


def glyph_alpha(im):
    """Alpha of the white artwork sitting on the blue, from how 'white' each pixel is,
    limited to the interior of the blue shape (drops the light halo on its outer edge)."""
    r, g, b, a = im.split()
    whiteness = ImageChops.darker(r, g).point(lambda v: max(0, min(255, round((v - 45) * 255 / (235 - 45)))))
    solid = a.point(lambda v: 255 if v > 200 else 0)
    interior = solid.filter(ImageFilter.MinFilter(31))   # ~15px inset from the shape edge
    return ImageChops.multiply(whiteness, interior)


def sample_gradient(im, bbox):
    x0, y0, x1, y1 = bbox
    px = im.load()

    def avg(cx, cy, rad=12):
        pts = [px[x, y] for x in range(cx - rad, cx + rad) for y in range(cy - rad, cy + rad)
               if px[x, y][3] > 250 and px[x, y][2] > px[x, y][0] + 60]
        return tuple(round(sum(p[i] for p in pts) / len(pts)) for i in range(3))

    inset = 0.16
    tl = avg(int(x0 + (x1 - x0) * inset), int(y0 + (y1 - y0) * inset))
    br = avg(int(x1 - (x1 - x0) * inset), int(y1 - (y1 - y0) * inset))
    return tl, br


def gradient(size, c0, c1):
    """Diagonal gradient, top-left c0 to bottom-right c1."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return g


def hexc(c):
    return "#%02X%02X%02X" % c


bbox = shape_bbox(icon_src)
c0, c1 = sample_gradient(icon_src, bbox)
alpha = glyph_alpha(icon_src)
gbox = alpha.point(lambda v: 255 if v > 40 else 0).getbbox()
glyph = Image.new("RGBA", icon_src.size, (255, 255, 255, 0))
glyph.putalpha(alpha)
glyph = glyph.crop(gbox)
print("shape bbox", bbox, "glyph bbox", gbox, "gradient", hexc(c0), "->", hexc(c1))


def place(canvas_size, art, frac):
    """Centre art on a transparent canvas, its longer side = frac of the canvas."""
    w, h = art.size
    s = frac * canvas_size / max(w, h)
    art = art.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    out = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    out.alpha_composite(art, ((canvas_size - art.width) // 2, (canvas_size - art.height) // 2))
    return out


# The phone glyph is visually heavier on the lower left (the handset) than the waves:
# nudge it a touch up/right so it reads as optically centred.
def nudge(img, dx, dy):
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(img, (dx, dy))
    return out


# 1) Full-bleed app icon.
icon = gradient(1024, c0, c1).convert("RGBA")
icon.alpha_composite(nudge(place(1024, glyph, 0.56), 8, -6))
icon.convert("RGB").save(root / "icon.png")

# 2) Adaptive foreground: glyph only, inside the ~66% safe zone.
nudge(place(1024, glyph, 0.40), 6, -4).save(root / "icon_foreground.png")

# 3) Rounded-square mark: the clean icon with the supplied artwork's corner radius (~22%).
rmask = Image.new("L", (2048, 2048), 0)
ImageDraw.Draw(rmask).rounded_rectangle([0, 0, 2047, 2047], radius=round(2048 * 0.22), fill=255)
sq = icon.copy()
sq.putalpha(rmask.resize((1024, 1024), Image.LANCZOS))
sq.resize((512, 512), Image.LANCZOS).save(root / "logo_mark.png")
place(512, sq, 0.62).save(root / "splash.png")

# 4) Glyph alone.
place(512, glyph, 0.92).save(root / "glyph.png")

# 5) Horizontal wordmark: a clean pill in the same gradient, with the supplied white
#    artwork (phone, divider, "Commit") extracted and placed back exactly where it was.
wb = shape_bbox(word_src)
W, H = wb[2] - wb[0], wb[3] - wb[1]
SS = 3
grad = gradient(max(W, H) * SS, c0, c1).resize((W * SS, H * SS)).convert("RGBA")
pill_mask = Image.new("L", (W * SS, H * SS), 0)
ImageDraw.Draw(pill_mask).rounded_rectangle([0, 0, W * SS - 1, H * SS - 1], radius=round(H * SS * 0.30), fill=255)
pill = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
pill.paste(grad, (0, 0), pill_mask)
pill = pill.resize((W, H), Image.LANCZOS)
art_a = glyph_alpha(word_src).crop(wb)
art = Image.new("RGBA", (W, H), (255, 255, 255, 0))
art.putalpha(art_a)
pill.alpha_composite(art)
pill.save(root / "logo_wordmark.png")
print("wordmark", (W, H), "| wrote", sorted(p.name for p in root.iterdir() if p.is_file()))
