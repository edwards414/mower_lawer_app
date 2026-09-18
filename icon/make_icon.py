# Generates icon/icon.png (1024x1024): a single grass blade on graphite,
# rendered with Pillow so the mark stays editable. Run from icon/:
#   python3 make_icon.py && cd .. && dart run flutter_launcher_icons

from PIL import Image, ImageDraw, ImageFilter, ImageChops
S, SS = 1024, 4
N = S * SS

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
def vgradient(size, top, bottom):
    img = Image.new("RGB", (size, size)); px = img.load()
    for y in range(size):
        c = lerp(top, bottom, y / (size - 1))
        for x in range(size): px[x, y] = c
    return img
def radial(size, center, radius, color, strength):
    layer = Image.new("L", (size, size), 0); d = ImageDraw.Draw(layer)
    steps = 48
    for i in range(steps, 0, -1):
        r = radius * i / steps; a = int(255 * strength * (1 - i / steps) ** 2)
        d.ellipse([center[0]-r, center[1]-r, center[0]+r, center[1]+r], fill=a)
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.22))
    col = Image.new("RGB", (size, size), color); col.putalpha(layer); return col
def bez(p0, p1, p2, p3, n=300):
    return [((1-t)**3*p0[0] + 3*(1-t)**2*t*p1[0] + 3*(1-t)*t**2*p2[0] + t**3*p3[0],
             (1-t)**3*p0[1] + 3*(1-t)**2*t*p1[1] + 3*(1-t)*t**2*p2[1] + t**3*p3[1]) for t in [i/n for i in range(n+1)]]

# background: graphite black with a faint cool vignette and a soft green light behind the blade
bg = vgradient(N, (19, 22, 21), (7, 9, 8)).convert("RGBA")
bg = Image.alpha_composite(bg, radial(N, (N*0.52, N*0.58), N*0.50, (34, 96, 62), 0.62))
# subtle top-left sheen
bg = Image.alpha_composite(bg, radial(N, (N*0.2, N*0.05), N*0.8, (70, 78, 74), 0.25))

# blade silhouette: base slightly left of centre, tip upper right, gentle S curve
base = (N*0.47, N*0.84)
tip  = (N*0.665, N*0.15)
left  = bez(base, (N*0.255, N*0.63), (N*0.46, N*0.36), tip)
right = bez(tip, (N*0.635, N*0.40), (N*0.62, N*0.66), base)
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).polygon(left + right, fill=255)

# blade fill: diagonal-ish gradient (light at tip, deep at base) via vertical gradient
grad = vgradient(N, (214, 246, 140), (36, 132, 78)).convert("RGBA")
blade = grad.copy(); blade.putalpha(mask)

# centre vein: darker, tapering (draw as thin polygon)
v = bez((N*0.475, N*0.80), (N*0.43, N*0.60), (N*0.555, N*0.40), (N*0.645, N*0.20))
vein = Image.new("RGBA", (N, N), (0, 0, 0, 0)); vd = ImageDraw.Draw(vein)
for i in range(len(v) - 1):
    t = i / len(v); w = max(2, int(N * 0.014 * (1 - t) + N * 0.002))
    vd.line([v[i], v[i+1]], fill=(18, 70, 44, 165), width=w)
vein = vein.filter(ImageFilter.GaussianBlur(N * 0.002))
vein.putalpha(ImageChops.multiply(vein.getchannel("A"), mask))
blade = Image.alpha_composite(blade, vein)

# edge light on the left rim (thin lighter stroke), for a slightly 3-D premium feel
rim = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(rim).line(left, fill=(235, 255, 190, 110), width=int(N * 0.006), joint="curve")
rim.putalpha(ImageChops.multiply(rim.getchannel("A"), mask))
blade = Image.alpha_composite(blade, rim)

# glow + drop shadow
glow = blade.copy().filter(ImageFilter.GaussianBlur(N * 0.035))
ga = glow.getchannel("A").point(lambda a: int(a * 0.55)); glow.putalpha(ga)
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(N * 0.02)).point(lambda a: int(a * 0.5)))
shadow = ImageChops.offset(shadow, int(N * 0.012), int(N * 0.02))

out = Image.alpha_composite(bg, glow)
out = Image.alpha_composite(out, shadow)
out = Image.alpha_composite(out, blade)
out = out.convert("RGB").resize((S, S), Image.LANCZOS)
out.save("icon.png")

# preview with iOS rounding at several sizes
def rounded(im, size):
    im = im.resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size-1, size-1], radius=int(size * 0.2237), fill=255)
    o = Image.new("RGBA", (size, size), (0, 0, 0, 0)); o.paste(im, (0, 0), m); return o
pv = Image.new("RGB", (1000, 420), (240, 240, 238))
x = 40
for s in (320, 180, 120, 76, 60, 40, 29):
    r = rounded(out, s); pv.paste(r, (x, 40 + (320 - s)), r); x += s + 28
pv.save("preview.png"); print("ok")
