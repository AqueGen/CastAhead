"""CastAhead project icon: the cast bar, and the call that arrives ahead of it.

400x400 PNG. Two chevrons running ahead of a filling cast bar - the addon's
one idea in a shape that still reads at 64px in an addon list. Amber on
slate, no text, because text dies at thumbnail size.

400 exactly, because CurseForge's logo cropper opens on a fixed 400x400
selection pinned to the top left: a larger image comes out cropped unless
the author drags the handles.
"""
from PIL import Image, ImageDraw, ImageFilter

S = 512      # drawn large, downsampled at the end so the curves stay smooth
OUT_SIZE = 400
BG = (24, 27, 34)
BG_EDGE = (44, 49, 60)
TRACK = (52, 57, 69)
AMBER = (255, 176, 46)
AMBER_DIM = (176, 116, 24)
WHITE = (240, 243, 248)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Rounded slate tile with a hairline edge, so the icon has a shape of its own
# against both light and dark list backgrounds.
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=96, fill=BG, outline=BG_EDGE, width=4)


def chevron(draw, x, y, w, h, thickness, color):
    """A > pointing right, centred on (x, y)."""
    half = h / 2
    outer = [(x - w / 2, y - half), (x + w / 2, y), (x - w / 2, y + half)]
    inner = [(x - w / 2 + thickness, y - half), (x + w / 2 - thickness, y),
             (x - w / 2 + thickness, y + half)]
    draw.line(outer, fill=color, width=thickness, joint="curve")
    del inner  # kept for readability: the line width IS the stroke


# Glow behind the chevrons: drawn on its own layer, blurred, composited under.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
chevron(gd, 214, 214, 92, 150, 34, AMBER + (110,))
chevron(gd, 310, 214, 92, 150, 34, AMBER + (110,))
img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(18)))

# The two chevrons: the second brighter, so the eye reads left to right.
chevron(d, 214, 214, 92, 150, 30, AMBER_DIM)
chevron(d, 310, 214, 92, 150, 30, AMBER)

# The cast bar underneath, filled two thirds, with the prediction tick sitting
# ahead of the fill where the cast will land.
bar_w, bar_h = 300, 46
x0 = (S - bar_w) // 2
y0 = 350
d.rounded_rectangle([x0, y0, x0 + bar_w, y0 + bar_h], radius=bar_h // 2, fill=TRACK)
d.rounded_rectangle([x0, y0, x0 + int(bar_w * 0.58), y0 + bar_h], radius=bar_h // 2, fill=AMBER)
tick = x0 + int(bar_w * 0.82)
d.rounded_rectangle([tick - 5, y0 - 20, tick + 5, y0 + bar_h + 20], radius=5, fill=WHITE)

out = "icon.png"
# Flattened onto the same slate as the tile: the upload widget refused the
# version with transparent corners, and black corners would read as a hard
# square on a light list row.
small = img.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
ground = Image.new("RGB", (OUT_SIZE, OUT_SIZE), BG)
ground.paste(small, (0, 0), small)
ground.save(out)
print(out)
