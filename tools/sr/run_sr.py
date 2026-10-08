"""Run one x4 super-resolution model over images (for eval_sr.py comparisons).

usage: run_sr.py MODEL WEIGHTS_DIR OUT_SUFFIX IMG [IMG ...]
MODEL: rrdb | compact | realesrgan | swinir | hat
Writes <img stem>_<OUT_SUFFIX>.png next to each input.
"""
import os
import sys
import time

import numpy as np
import torch
from PIL import Image
from spandrel import ModelLoader

DEV = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

WEIGHTS = {
    # fine-tuned on NLSC tiles by finetune.py
    "rrdb": "finetuned_nlsc_x4.pth",
    "compact": "finetuned_compact_x4.pth",
    # off-the-shelf baselines
    "realesrgan": "RealESRGAN_x4plus.pth",
    "swinir": "swinir_L_real_gan_x4.pth",
    "hat": "Real_HAT_GAN_sharper.pth",
}


def main():
    model, wdir, suffix, *imgs = sys.argv[1:]
    desc = ModelLoader(device=DEV).load_from_file(os.path.join(wdir, WEIGHTS[model]))
    desc.model.eval()
    print(f"loaded {desc.architecture.name} x{desc.scale}")
    for p in imgs:
        a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32) / 255.0
        t0 = time.time()
        with torch.no_grad():
            out = desc(torch.from_numpy(a).permute(2, 0, 1)[None].to(DEV))
        o = out.clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy()
        dst = f"{os.path.splitext(p)[0]}_{suffix}.png"
        Image.fromarray((o * 255 + 0.5).astype(np.uint8)).save(dst)
        print(f"{os.path.basename(p)} -> {o.shape[1]}x{o.shape[0]} in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
