# AI base map (x4 super-resolution)

The satellite view can overlay the NLSC aerial tiles (z19, ~27 cm/px) with
x4 super-resolved tiles (~7 cm/px equivalent). The extra detail is model
output, not survey data: it is for display only, never for tracing mow
boundaries.

The app (`lib/services/ai_basemap_service.dart`) gets a tile in one of two ways:

- **Cloud**: precomputed tiles in the `mower-sr-tiles` R2 bucket, served at
  `https://sr.mower.fxrbindi.com/v1/<model>/19/<x>/<y>.webp` (1024 px WebP,
  `Cache-Control: immutable`; bump `v1` when the model changes).
- **On device**: fetch the NLSC tile and run `assets/models/sr_compact_nlsc_x4.tflite`.
  The app uses this only when R2 has no tile.

`integration_test/ai_basemap_benchmark_test.dart` times both on a phone.

## Models

Both start from public Real-ESRGAN weights and are fine-tuned on NLSC tiles
around the site (`finetune.py`: synthetic x4 degradation of z19 tiles,
L1 + VGG perceptual + GAN). Hold-out check (z19 down to 1.1 m/px and back up
again, scored against the original z19 tile):

| model | params | PSNR dB ↑ | LPIPS ↓ | used for |
|---|---|---|---|---|
| bicubic | – | 32.24 | 0.416 | – |
| Real-ESRGAN x4plus (stock) | 16.7 M | 29.99 | 0.228 | – |
| **rrdb** (x4plus fine-tuned) | 16.7 M | 31.62 | **0.145** | cloud tiles |
| **compact** (general-x4v3 fine-tuned) | 1.2 M | **32.61** | 0.164 | on device |

## Rebuild

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
W=weights   # RealESRGAN_x4plus.pth, RealESRGAN_x4plus_netD.pth, realesr-general-x4v3.pth
            # from github.com/xinntao/Real-ESRGAN/releases

# 1. training tiles: NLSC z19 within 750 m of the site, 200 m held out
.venv/bin/python fetch_train_tiles.py 23.6939508 120.5376539 750 200 train_tiles

# 2. fine-tune (Apple GPU via MPS; FT_BATCH/FT_HR shrink memory use)
FT_BATCH=4 FT_HR=128 .venv/bin/python finetune.py train_tiles $W 1200
FT_BATCH=8 FT_HR=128 .venv/bin/python finetune.py train_tiles $W 2000 \
    realesr-general-x4v3.pth finetuned_compact_x4.pth

# 3. TFLite for the app (and validated against PyTorch)
.venv/bin/python export_tflite.py $W/finetuned_compact_x4.pth out/compact compact_nlsc_x4 train_tiles/<any>.jpg
cp out/compact/compact_nlsc_x4_float32.tflite ../../assets/models/sr_compact_nlsc_x4.tflite

# 4. cloud tiles for the site (+-300 m) and upload (needs `wrangler login`)
.venv/bin/python build_sr_tiles.py rrdb $W/finetuned_nlsc_x4.pth 23.6939508 120.5376539 300 r2
./upload_r2.sh mower-sr-tiles r2 v1
```

`eval_sr.py` + `run_sr.py` reproduce the hold-out table (`fetch_area.py`
fetches the ground-truth crop).

NLSC imagery is under the Open Government Data License: keep the
「© 內政部國土測繪中心」 attribution on anything derived from it.
