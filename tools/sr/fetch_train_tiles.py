"""Download NLSC z19 tiles around a point for fine-tuning, skipping a hold-out radius.

usage: fetch_train_tiles.py LAT LON HALF_SIZE_M HOLDOUT_M OUT_DIR
"""
import math
import os
import sys
import time
import urllib.request

URL = "https://wmts.nlsc.gov.tw/wmts/PHOTO2/default/GoogleMapsCompatible/{z}/{y}/{x}"
Z = 19


def tile_xy(lat, lon, z):
    n = 2**z
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n


def main():
    lat, lon, half, holdout = map(float, sys.argv[1:5])
    out = sys.argv[5]
    os.makedirs(out, exist_ok=True)
    tile_m = 156543.03392 * math.cos(math.radians(lat)) / 2**Z * 256
    cx, cy = tile_xy(lat, lon, Z)
    r = int(half / tile_m)
    got = skipped = 0
    for ty in range(int(cy) - r, int(cy) + r + 1):
        for tx in range(int(cx) - r, int(cx) + r + 1):
            if math.hypot(tx + 0.5 - cx, ty + 0.5 - cy) * tile_m < holdout:
                skipped += 1
                continue
            path = os.path.join(out, f"{tx}_{ty}.jpg")
            if os.path.exists(path):
                got += 1
                continue
            req = urllib.request.Request(URL.format(z=Z, x=tx, y=ty), headers={"User-Agent": "mower-sr-test/0.1"})
            for attempt in range(3):
                try:
                    data = urllib.request.urlopen(req, timeout=30).read()
                    break
                except Exception as e:  # noqa: BLE001
                    print("retry", tx, ty, e)
                    time.sleep(2)
            else:
                continue
            with open(path, "wb") as f:
                f.write(data)
            got += 1
            time.sleep(0.05)
    print(f"{got} tiles, {skipped} held out, tile {tile_m:.1f} m")


if __name__ == "__main__":
    main()
