"""Precompute x4 SR tiles for an area and lay them out for R2.

For every NLSC z19 tile within HALF_M of (LAT, LON), fetch the 256 px aerial
tile, run the model, and write OUT_DIR/v1/<MODEL_KEY>/19/<x>/<y>.webp
(1024 px). Upload the OUT_DIR tree with upload_r2.sh.

usage: build_sr_tiles.py MODEL_KEY MODEL_PTH LAT LON HALF_M OUT_DIR
"""
import io
import math
import os
import sys
import time
import urllib.request

import numpy as np
import torch
from PIL import Image
from spandrel import ModelLoader

Z = 19
NLSC = "https://wmts.nlsc.gov.tw/wmts/PHOTO2/default/GoogleMapsCompatible/{z}/{y}/{x}"
DEV = torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def tile_xy(lat, lon):
    n = 2**Z
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n


def main():
    key, pth, lat, lon, half, out = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:6]), sys.argv[6]
    desc = ModelLoader(device=DEV).load_from_file(pth)
    desc.model.eval()
    tile_m = 156543.03392 * math.cos(math.radians(lat)) / 2**Z * 256
    cx, cy = tile_xy(lat, lon)
    r = math.ceil(half / tile_m)
    cache = os.path.join(out, ".nlsc")
    os.makedirs(cache, exist_ok=True)
    n, t_sr, size = 0, 0.0, 0
    for ty in range(int(cy) - r, int(cy) + r + 1):
        for tx in range(int(cx) - r, int(cx) + r + 1):
            src = os.path.join(cache, f"{tx}_{ty}.jpg")
            if not os.path.exists(src):
                req = urllib.request.Request(NLSC.format(z=Z, x=tx, y=ty), headers={"User-Agent": "mower-sr/1"})
                with open(src, "wb") as f:
                    f.write(urllib.request.urlopen(req, timeout=30).read())
            im = Image.open(src).convert("RGB")
            a = torch.from_numpy(np.asarray(im, dtype=np.float32) / 255).permute(2, 0, 1)[None].to(DEV)
            t0 = time.time()
            with torch.no_grad():
                o = desc(a).clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy()
            t_sr += time.time() - t0
            dst = os.path.join(out, "v1", key, str(Z), str(tx), f"{ty}.webp")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            buf = io.BytesIO()
            Image.fromarray((o * 255 + 0.5).astype(np.uint8)).save(buf, "WEBP", quality=85, method=4)
            with open(dst, "wb") as f:
                f.write(buf.getvalue())
            n += 1
            size += buf.tell()
    print(f"{key}: {n} tiles ({2 * r + 1}x{2 * r + 1}), SR {t_sr / n:.2f}s/tile on {DEV}, avg {size / n / 1024:.0f} KiB")


if __name__ == "__main__":
    main()
