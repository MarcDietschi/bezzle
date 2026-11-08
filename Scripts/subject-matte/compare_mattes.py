# compare_mattes.py <reference folder> <folder>...
# Measures Windows' mattes against a reference, photo by photo: the <photo>-matte.f32 files (2,048 ×
# 2,048 floats) that `bezzle-render <fonts> cutout <out>` writes with BEZZLE_MATTE_RAW, as the half-
# precision model on a graphics card (BEZZLE_MATTE_DEVICE=gpu) against the full-precision one
# (BEZZLE_MATTE_MODEL=…BiRefNet-fp32.onnx, BEZZLE_MATTE_DEVICE=cpu). For each: the mean difference in
# alpha (%), the same on the edge alone (where either is between 2% and 98% solid), the share plainly
# wrong (off by more than half), the overlap of what is at least half solid (IoU) and the largest
# difference. It runs no model code.
import os
import sys
import numpy as np


def matte(path):
    a = np.fromfile(path, dtype=np.float32)
    side = int(round(len(a) ** 0.5))
    return a.reshape(side, side)


def compare(a, b):
    d = np.abs(a - b)
    edge = ((a > 0.02) & (a < 0.98)) | ((b > 0.02) & (b < 0.98))
    sa, sb = a >= 0.5, b >= 0.5
    union = (sa | sb).sum()
    return [d.mean() * 100, d[edge].mean() * 100 if edge.any() else 0, (d > 0.5).mean() * 100,
            (sa & sb).sum() / union * 100 if union else 100, d.max()]


reference = sys.argv[1]
print(f"{'photo':16} {'folder':20} {'mean %':>7} {'edge %':>7} {'gross %':>8} {'IoU %':>7} {'max':>6}")
for folder in sys.argv[2:]:
    rows = []
    for name in sorted(os.listdir(reference)):
        if not name.endswith('-matte.f32') or not os.path.exists(os.path.join(folder, name)):
            continue
        row = compare(matte(os.path.join(reference, name)), matte(os.path.join(folder, name)))
        rows.append(row)
        print(f"{name[:-10]:16} {os.path.basename(folder.rstrip('/'))[:20]:20} {row[0]:7.3f} {row[1]:7.2f} {row[2]:8.3f} {row[3]:7.2f} {row[4]:6.3f}")
    if rows:
        m = np.array(rows)
        print(f"{'mean':16} {os.path.basename(folder.rstrip('/'))[:20]:20} {m[:, 0].mean():7.3f} {m[:, 1].mean():7.2f} {m[:, 2].mean():8.3f} {m[:, 3].mean():7.2f} {m[:, 4].max():6.3f}")
