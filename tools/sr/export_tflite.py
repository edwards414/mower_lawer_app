"""Export an x4 SR model (.pth, any spandrel arch) to TFLite for the app.

The TFLite model takes one NLSC z19 tile, NHWC float32 [1,256,256,3] in 0..1,
and returns the x4 tile as [1,1024,1024,3] or (when onnx2tf keeps the
PixelShuffle layout) [1,3,1024,1024]. Values are not clamped in-graph: Clip
becomes RELU_0_TO_1, which older TFLite runtimes lack; the app clamps.

usage: export_tflite.py MODEL_PTH OUT_DIR NAME TEST_TILE.jpg
writes OUT_DIR/NAME.onnx and OUT_DIR/NAME_float32.tflite
"""
import os
import sys
import time

import numpy as np
import torch
from PIL import Image
from spandrel import ModelLoader

TILE = 256


def main():
    pth, out_dir, name, test_tile = sys.argv[1:]
    os.makedirs(out_dir, exist_ok=True)
    desc = ModelLoader(device="cpu").load_from_file(pth)
    net = desc.model.float().eval()
    print(f"{desc.architecture.name} x{desc.scale}, {sum(p.numel() for p in net.parameters()) / 1e6:.2f}M params")

    onnx_path = os.path.join(out_dir, f"{name}.onnx")
    dummy = torch.rand(1, 3, TILE, TILE)
    try:
        torch.onnx.export(net, dummy, onnx_path, input_names=["input"], output_names=["output"], opset_version=17, dynamo=False)
    except TypeError:
        torch.onnx.export(net, dummy, onnx_path, input_names=["input"], output_names=["output"], opset_version=17)
    print("onnx ->", onnx_path)

    import onnx2tf

    stem = os.path.splitext(os.path.basename(onnx_path))[0]
    # Ships as float32: GPU delegates may still run it in fp16. onnx2tf's own
    # *_float16.tflite has fp16 I/O, which the CPU kernels refuse; not used.
    onnx2tf.convert(
        input_onnx_file_path=onnx_path,
        output_folder_path=out_dir,
        copy_onnx_input_output_names_to_tflite=True,
        non_verbose=True,
    )

    # Validate against PyTorch on a real tile.
    from ai_edge_litert.interpreter import Interpreter

    img = np.asarray(Image.open(test_tile).convert("RGB").resize((TILE, TILE)), dtype=np.float32) / 255.0
    with torch.no_grad():
        ref = net(torch.from_numpy(img).permute(2, 0, 1)[None]).clamp(0, 1).numpy()[0].transpose(1, 2, 0)
    for prec in ("float32",):
        path = os.path.join(out_dir, f"{stem}_{prec}.tflite")
        it = Interpreter(model_path=path, num_threads=4)
        it.allocate_tensors()
        inp, outp = it.get_input_details()[0], it.get_output_details()[0]
        it.set_tensor(inp["index"], img[None])
        t0 = time.time()
        it.invoke()
        dt = time.time() - t0
        out = it.get_tensor(outp["index"])[0]
        if out.shape[0] == 3:  # NCHW
            out = out.transpose(1, 2, 0)
        out = out.clip(0, 1)
        diff = np.abs(out - ref)
        print(
            f"{prec}: {os.path.getsize(path) / 1e6:.1f} MB, in {inp['shape'].tolist()} out {outp['shape'].tolist()}, "
            f"max|Δ| {diff.max():.4f} mean|Δ| {diff.mean():.5f}, Mac CPU {dt:.2f}s"
        )
        Image.fromarray((out * 255 + 0.5).astype(np.uint8)).save(os.path.join(out_dir, f"{stem}_{prec}_check.png"))


if __name__ == "__main__":
    main()
