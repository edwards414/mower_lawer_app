"""Fetch XYZ tiles covering a lat/lon box at one zoom, stitch, crop to the box.

usage: fetch_area.py SOURCE ZOOM LAT LON HALF_W_M HALF_H_M OUT.png
"""
import io
import math
import sys
import urllib.request

from PIL import Image

SOURCES = {
    "nlsc": "https://wmts.nlsc.gov.tw/wmts/PHOTO2/default/GoogleMapsCompatible/{z}/{y}/{x}",
    "esri": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
}


def world_px(lat, lon, z, ts=256):
    n = ts * 2**z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def main():
    src, z, lat, lon, hw, hh, out = sys.argv[1:]
    z, lat, lon, hw, hh = int(z), float(lat), float(lon), float(hw), float(hh)
    m_per_deg_lat = 111_320
    m_per_deg_lon = 111_320 * math.cos(math.radians(lat))
    x0, y0 = world_px(lat + hh / m_per_deg_lat, lon - hw / m_per_deg_lon, z)
    x1, y1 = world_px(lat - hh / m_per_deg_lat, lon + hw / m_per_deg_lon, z)
    tx0, ty0, tx1, ty1 = int(x0 // 256), int(y0 // 256), int(x1 // 256), int(y1 // 256)
    canvas = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256))
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            url = SOURCES[src].format(z=z, x=tx, y=ty)
            req = urllib.request.Request(url, headers={"User-Agent": "mower-sr-test/0.1"})
            data = urllib.request.urlopen(req, timeout=30).read()
            tile = Image.open(io.BytesIO(data)).convert("RGB")
            if tile.size != (256, 256):
                tile = tile.resize((256, 256), Image.LANCZOS)
            canvas.paste(tile, ((tx - tx0) * 256, (ty - ty0) * 256))
    box = (round(x0 - tx0 * 256), round(y0 - ty0 * 256), round(x1 - tx0 * 256), round(y1 - ty0 * 256))
    crop = canvas.crop(box)
    crop.save(out)
    gsd = 156543.03392 * math.cos(math.radians(lat)) / 2**z
    print(f"{src} z{z}: {crop.size[0]}x{crop.size[1]} px, {gsd*100:.1f} cm/px -> {out}")


if __name__ == "__main__":
    main()
