"""Ground-truth check at the scale where truth exists.

  prep:  eval_sr.py prep EVAL_DIR      -> truth.png  =>  lr.png (x4 down + JPEG), lr_bicubic.png
  score: eval_sr.py score EVAL_DIR SUFFIX [SUFFIX ...]  -> PSNR / LPIPS of lr_<suffix>.png vs truth.png
"""
import io
import os
import sys

import numpy as np
from PIL import Image


def prep(d):
    truth = Image.open(os.path.join(d, "truth.png")).convert("RGB")
    w, h = (truth.size[0] // 4) * 4, (truth.size[1] // 4) * 4
    truth = truth.crop((0, 0, w, h))
    truth.save(os.path.join(d, "truth.png"))
    lr = truth.resize((w // 4, h // 4), Image.BICUBIC)
    buf = io.BytesIO()
    lr.save(buf, "JPEG", quality=85)
    lr = Image.open(buf).convert("RGB")
    lr.save(os.path.join(d, "lr.png"))
    lr.resize((w, h), Image.BICUBIC).save(os.path.join(d, "lr_bicubic.png"))
    print("truth", truth.size, "lr", lr.size)


def score(d, suffixes):
    import lpips
    import torch

    net = lpips.LPIPS(net="alex", verbose=False)
    truth = np.asarray(Image.open(os.path.join(d, "truth.png")).convert("RGB"), dtype=np.float32) / 255
    t_truth = torch.from_numpy(truth).permute(2, 0, 1)[None] * 2 - 1
    print(f"{'model':<12} {'PSNR dB (高=像真圖)':>18} {'LPIPS (低=看起來像)':>20}")
    rows = {}
    for s in suffixes:
        im = Image.open(os.path.join(d, f"lr_{s}.png")).convert("RGB").crop((0, 0, truth.shape[1], truth.shape[0]))
        a = np.asarray(im, dtype=np.float32) / 255
        psnr = 10 * np.log10(1 / np.mean((a - truth) ** 2))
        with torch.no_grad():
            lp = net(torch.from_numpy(a).permute(2, 0, 1)[None] * 2 - 1, t_truth).item()
        print(f"{s:<12} {psnr:>18.2f} {lp:>20.3f}")
        rows[s] = {"psnr": round(float(psnr), 2), "lpips": round(lp, 3)}
    import json

    with open(os.path.join(d, "scores.json"), "w") as f:
        json.dump(rows, f, indent=1)


if __name__ == "__main__":
    if sys.argv[1] == "prep":
        prep(sys.argv[2])
    else:
        score(sys.argv[2], sys.argv[3:])
