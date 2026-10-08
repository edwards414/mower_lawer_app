"""Fine-tune Real-ESRGAN x4plus on NLSC aerial tiles (self-supervised, cross-scale).

HR = random 192px crops of z19 tiles (27 cm/px); LR = synthetically degraded x4
downsample (1.1 m/px). Losses follow Real-ESRGAN: L1 + VGG19 perceptual + GAN,
with an EMA copy of the generator saved at the end.

usage: finetune.py TILES_DIR WEIGHTS_DIR ITERS [BASE_PTH] [OUT_PTH]
"""
import glob
import io
import os
import random
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchvision
from PIL import Image, ImageFilter
from torch.nn.utils import spectral_norm

DEV = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
HR = int(os.environ.get("FT_HR", 192))
BATCH = int(os.environ.get("FT_BATCH", 8))


class UNetDiscriminatorSN(nn.Module):
    """Real-ESRGAN's discriminator (basicsr.archs.discriminator_arch)."""

    def __init__(self, num_in_ch=3, num_feat=64):
        super().__init__()
        self.conv0 = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.conv1 = spectral_norm(nn.Conv2d(num_feat, num_feat * 2, 4, 2, 1, bias=False))
        self.conv2 = spectral_norm(nn.Conv2d(num_feat * 2, num_feat * 4, 4, 2, 1, bias=False))
        self.conv3 = spectral_norm(nn.Conv2d(num_feat * 4, num_feat * 8, 4, 2, 1, bias=False))
        self.conv4 = spectral_norm(nn.Conv2d(num_feat * 8, num_feat * 4, 3, 1, 1, bias=False))
        self.conv5 = spectral_norm(nn.Conv2d(num_feat * 4, num_feat * 2, 3, 1, 1, bias=False))
        self.conv6 = spectral_norm(nn.Conv2d(num_feat * 2, num_feat, 3, 1, 1, bias=False))
        self.conv7 = spectral_norm(nn.Conv2d(num_feat, num_feat, 3, 1, 1, bias=False))
        self.conv8 = spectral_norm(nn.Conv2d(num_feat, num_feat, 3, 1, 1, bias=False))
        self.conv9 = nn.Conv2d(num_feat, 1, 3, 1, 1)

    def forward(self, x):
        lr = lambda t: F.leaky_relu(t, 0.2)  # noqa: E731
        up = lambda t: F.interpolate(t, scale_factor=2, mode="bilinear", align_corners=False)  # noqa: E731
        x0 = lr(self.conv0(x))
        x1 = lr(self.conv1(x0))
        x2 = lr(self.conv2(x1))
        x3 = lr(self.conv3(x2))
        x4 = lr(self.conv4(up(x3))) + x2
        x5 = lr(self.conv5(up(x4))) + x1
        x6 = lr(self.conv6(up(x5))) + x0
        return self.conv9(lr(self.conv8(lr(self.conv7(x6)))))


class VGGPerceptual(nn.Module):
    """VGG19 features before ReLU at conv1_2/2_2/3_4/4_4/5_4, weights as in Real-ESRGAN."""

    LAYERS = {2: 0.1, 7: 0.1, 16: 1.0, 25: 1.0, 34: 1.0}

    def __init__(self):
        super().__init__()
        vgg = torchvision.models.vgg19(weights=torchvision.models.VGG19_Weights.IMAGENET1K_V1).features[:35]
        self.vgg = vgg.eval().requires_grad_(False)
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x, y):
        x, y = (x - self.mean) / self.std, (y - self.mean) / self.std
        loss = 0.0
        for i, layer in enumerate(self.vgg):
            x, y = layer(x), layer(y)
            if i in self.LAYERS:
                loss = loss + self.LAYERS[i] * F.l1_loss(x, y)
        return loss


def degrade(hr):
    """One-order Real-ESRGAN-style degradation: blur -> x4 resize -> noise -> JPEG."""
    im = hr.filter(ImageFilter.GaussianBlur(random.uniform(0.2, 1.6)))
    im = im.resize((HR // 4, HR // 4), random.choice([Image.BICUBIC, Image.BILINEAR, Image.BOX]))
    a = np.asarray(im, dtype=np.float32)
    a = a + np.random.normal(0, random.uniform(0, 4), a.shape)
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=random.randint(60, 95))
    return Image.open(buf).convert("RGB")


def batch(tiles):
    hrs, lrs = [], []
    for _ in range(BATCH):
        t = random.choice(tiles)
        x, y = random.randint(0, 256 - HR), random.randint(0, 256 - HR)
        hr = t.crop((x, y, x + HR, y + HR))
        if random.random() < 0.5:
            hr = hr.transpose(Image.FLIP_LEFT_RIGHT)
        hr = hr.rotate(random.choice([0, 90, 180, 270]))
        hrs.append(np.asarray(hr, dtype=np.float32) / 255)
        lrs.append(np.asarray(degrade(hr), dtype=np.float32) / 255)
    f = lambda arr: torch.from_numpy(np.stack(arr)).permute(0, 3, 1, 2).to(DEV)  # noqa: E731
    return f(lrs), f(hrs)


def main():
    tiles_dir, wdir, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
    base = sys.argv[4] if len(sys.argv) > 4 else "RealESRGAN_x4plus.pth"
    out_name = sys.argv[5] if len(sys.argv) > 5 else "finetuned_nlsc_x4.pth"
    from spandrel import ModelLoader

    tiles = [Image.open(p).convert("RGB") for p in sorted(glob.glob(os.path.join(tiles_dir, "*.jpg")))]
    tiles = [t for t in tiles if t.size == (256, 256)]
    print(f"{len(tiles)} training tiles on {DEV}")

    desc = ModelLoader(device=DEV).load_from_file(os.path.join(wdir, base))
    net_g = desc.model.train()
    print(f"base {base}: {desc.architecture.name}, {sum(p.numel() for p in net_g.parameters())/1e6:.2f}M params")
    ema = {k: v.detach().clone() for k, v in net_g.state_dict().items()}
    net_d = UNetDiscriminatorSN().to(DEV)
    sd = torch.load(os.path.join(wdir, "RealESRGAN_x4plus_netD.pth"), map_location="cpu")
    missing = net_d.load_state_dict(sd.get("params", sd), strict=False)
    print("netD load:", missing)
    net_d.train()
    percep = VGGPerceptual().to(DEV)
    opt_g = torch.optim.Adam(net_g.parameters(), lr=1e-4, betas=(0.9, 0.99))
    opt_d = torch.optim.Adam(net_d.parameters(), lr=1e-4, betas=(0.9, 0.99))
    bce = nn.BCEWithLogitsLoss()

    t0 = time.time()
    for it in range(1, iters + 1):
        lr_img, hr_img = batch(tiles)
        # generator
        net_d.requires_grad_(False)
        sr = net_g(lr_img)
        fake_logit = net_d(sr)
        l_pix = F.l1_loss(sr, hr_img)
        l_per = percep(sr, hr_img)
        l_gan = bce(fake_logit, torch.ones_like(fake_logit))
        loss_g = l_pix + l_per + 0.1 * l_gan
        opt_g.zero_grad()
        loss_g.backward()
        opt_g.step()
        # discriminator
        net_d.requires_grad_(True)
        real_logit = net_d(hr_img)
        fake_logit = net_d(sr.detach())
        loss_d = bce(real_logit, torch.ones_like(real_logit)) + bce(fake_logit, torch.zeros_like(fake_logit))
        opt_d.zero_grad()
        loss_d.backward()
        opt_d.step()
        # EMA
        with torch.no_grad():
            for k, v in net_g.state_dict().items():
                ema[k].mul_(0.995).add_(v.detach(), alpha=0.005) if v.dtype.is_floating_point else ema[k].copy_(v)
        if it % 25 == 0 or it == 1:
            el = time.time() - t0
            print(
                f"it {it}/{iters} pix {l_pix.item():.4f} per {l_per.item():.3f} gan {l_gan.item():.3f} "
                f"d {loss_d.item():.3f} | {el / it:.2f}s/it, eta {(iters - it) * el / it / 60:.1f} min",
                flush=True,
            )

    out = os.path.join(wdir, out_name)
    torch.save({"params_ema": {k: v.cpu() for k, v in ema.items()}}, out)
    print("saved", out)


if __name__ == "__main__":
    main()
